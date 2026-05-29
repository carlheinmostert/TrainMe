---
name: manage-issues-intake
description: Capture a tangent — a new feature, bug, or idea that surfaced mid-session — into a rich, front-loaded GitHub issue, so the live session stays focused and the work gets handled in batch by the manage-issues sweep. Use proactively whenever something raised is a distinct, scope-expanding unit of work (not part of the current task), or on an explicit "park it" / "log it" / "capture it" / "stack it" / "file an issue for that".
---

# manage-issues-intake

The **capture** half of the managed-issues system. It files a session tangent as a GitHub issue and gets out of the way, so a working session never gets muddied by new features/bugs/ideas. Its partner is **`manage-issues`** (the unattended sweep) — the *batch-management* half. The two skills never talk directly; they meet only through GitHub issues.

**This skill complies with the `manage-issues` rules.** Every issue it files lands **bare in TRIAGE**: a clean, rich body, **no `status:` label, no `bug`/`enhancement` pre-classification, no assignee.** The sweep classifies and routes it.

## When it fires

- **Proactively** — when something raised in a session is a **distinct, scope-expanding unit of work**: not a clarification, not a sub-step of the current task, not a correction of what's being worked on. (The always-on trigger lives in the repo's `CLAUDE.md`, installed by `manage-issues init`.)
- **On explicit request** — "park it", "log it", "capture it", "**stack it**", "file an issue for that". By default **one issue per distinct item**; if Carl rattles off several at once he can say **"stack these as one"** and intake bundles that burst into a single checklist issue. ("stack" now routes here — it retires the old "queue to a local stack file" mechanism; durable issues replace the ephemeral list.)
- Either way: **file it, drop a one-line notice, and continue** — "Filed #123 (dark-mode export) — parking it, back to the migration." Never block the conversation to ask permission. A one-word veto from Carl pulls it back (close the issue).

## How it runs

**In a background sub-agent.** Writing a good front-loaded body takes a moment, and the whole point is not to cost the session any momentum — so the parent dispatches intake in the background with the tangent's context and keeps talking; intake reports the issue number when done.

## Steps

1. **Resolve the repo** — the project being worked on (`gh repo view --json nameWithOwner -q .nameWithOwner`). If there's no clear repo context, surface that to Carl rather than guessing where to file.
2. **De-dup, but bias to capture.** Search open issues for a clear match (`gh issue list --search "<keywords>" --state open`; skim titles/bodies).
   - **Clear match** → don't open a duplicate; add a one-line comment to the existing issue ("came up again in session — same thing") and report *that* number.
   - **Uncertain / no match** → file new. A near-duplicate is a cheap annoyance; a *lost* capture defeats the discipline. When in doubt, capture.
3. **Write a rich, front-loaded body** from the session context — capture everything known *now*, while it's cheap:
   - a concise, specific **title**;
   - a **"what surfaced and why it matters"** paragraph;
   - relevant **file paths / links / code snippets** from the session (repo-relative paths);
   - the checklist fields the sweep will want — **bug:** repro · expected vs actual · surface; **feature:** the job-to-be-done · who it's for · what success looks like · constraints.
4. **File it bare:** `gh issue create --repo <repo> --title "…" --body-file <tmp>` with **no labels, no assignee**. Do not pre-classify; the sweep does that.
5. **Report** the issue number + URL back to the parent for the one-line notice.

## Hard rules

- **Comply with `manage-issues`:** bare TRIAGE — no `status:` label, no `bug`/`enhancement`, no assignee. The sweep owns classification, labels, board placement, and assignment.
- **Capture, don't solve.** Don't diagnose a fix, don't start coding, don't classify. Just record the work so future-you (the sweep) or Carl can act with full context.
- **Don't derail.** File + one-line notice + continue. The proactive bar is "distinct, scope-expanding" — when unsure whether something is a tangent or part of the task, ask in one line or err toward leaving the session alone.
- Repo-relative paths in the body.

## Encodes

- `feedback_delegate_coding` · `feedback_agent_worktree_isolation` (runs as a background sub-agent, repo-relative paths)
- `feedback_no_popups_ever` (default body + file, no modal)
- Complies with the `manage-issues` state machine (lands bare in TRIAGE)
