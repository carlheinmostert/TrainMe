---
name: manage-issues-intake
description: Capture a tangent — a new feature, bug, or idea that surfaced mid-session — into a rich, front-loaded GitHub issue, so the live session stays focused and the work gets handled in batch by the manage-issues sweep. Use ONLY on Carl's explicit "park it" / "log it" / "capture it" / "file an issue for that". Never fire proactively — findings return to the conversation as stack items, and Carl decides what becomes an issue.
---

# manage-issues-intake

The **capture** half of the managed-issues system. It files a session tangent as a GitHub issue and gets out of the way, so a working session never gets muddied by new features/bugs/ideas. Its partner is **`manage-issues`** (the unattended sweep) — the *batch-management* half. The two skills never talk directly; they meet only through GitHub issues.

**This skill complies with the `manage-issues` rules.** Every issue it files lands **bare in TRIAGE**: a clean, rich body, **no `status:` label, no `bug`/`enhancement` pre-classification, no assignee.** The sweep classifies and routes it.

## When it fires

- **On explicit request only** — "park it", "log it", "capture it", "file an
  issue for that", from Carl. By default **one issue per distinct item**; if he
  rattles off several at once he can say **"park these as one"** and intake
  bundles that burst into a single checklist issue.
- **Never proactively.** A session's own judgement that something is
  scope-expanding is not a trigger. Findings go back into the conversation as
  stack items; Carl decides what gets deferred to an issue. This binds
  sub-agents too — a sub-agent reports findings to its parent and never files.
- Once he has asked: file it, drop a one-line notice, and continue.

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
- **Don't derail.** File + one-line notice + continue. There is no proactive bar, because there is no proactive filing. If you think something deserves an issue, say so in the conversation and let Carl call it.
- Repo-relative paths in the body.

## Encodes

- `feedback_delegate_coding` · `feedback_agent_worktree_isolation` (runs as a background sub-agent, repo-relative paths)
- `feedback_no_popups_ever` (default body + file, no modal)
- Complies with the `manage-issues` state machine (lands bare in TRIAGE)
