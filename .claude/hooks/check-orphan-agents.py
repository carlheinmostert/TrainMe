#!/usr/bin/env python3
"""
SessionStart hook — detects orphaned background sub-agents from prior
sessions and emits a system reminder so the user can ask Claude to
resurrect them.

Background (2026-05-03): Claude Code spawns background sub-agents with
`isolation: "worktree"` into worktrees under `.claude/worktrees/agent-<id>/`.
When the parent session dies (crash, accidental close, OS reboot), the
background agents die with it — but their uncommitted work remains in
the worktree. Today there's no way to discover that without forensic
work. This hook fixes that.

Detection flow:
  1. Read `.claude/state/agent-registry.jsonl` (written by the
     record-agent-dispatch.py PostToolUse hook).
  2. For each entry from a DIFFERENT session_id than the current one,
     where isolation == "worktree":
       a. Worktree must exist on disk.
       b. `git status --porcelain` must report >= 1 line of dirty state.
          (Clean worktrees mean either the agent never started or it
          shipped a PR; either way, no orphan to recover.)
       c. If a PR has merged for the worktree's branch, skip — the
          work shipped, the worktree is just leftover.
  3. Emit a system reminder listing each orphan with its description,
     diff size, last-touch time, and pointer to the brief sidecar.

Output is plain stdout — Claude Code injects it into the session
context as additionalContext (per the SessionStart hook contract).

Performance budget: typical-case <500ms with parallel `gh` calls.
We:
  * Read the registry in one pass (cap at MAX_REGISTRY_ENTRIES).
  * Skip the (slow) `gh pr list` call entirely if there are no
    candidate orphans.
  * Run gh checks in parallel via ThreadPoolExecutor — wall-clock
    cost stays close to a single call regardless of orphan count.
  * Cap output at MAX_OUTPUT_ENTRIES so a rotted registry can't
    drown a fresh session in noise.

Safety: any exception → exit 0 silently with no output. A broken
SessionStart hook must never block session start.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


MAX_REGISTRY_ENTRIES = 200
MAX_OUTPUT_ENTRIES = 10
GIT_TIMEOUT_S = 2.0
GH_TIMEOUT_S = 4.0
GH_POOL_SIZE = 6  # cap parallelism to be polite to the GH API


def _resolve_paths():
    """
    Locate the project root + state dir. Walks up from cwd looking for
    `.claude/`. Returns (project_root, state_dir).
    """
    cwd = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
    for candidate in [cwd, *cwd.parents]:
        if (candidate / ".claude").is_dir():
            return candidate, candidate / ".claude" / "state"
    return cwd, cwd / ".claude" / "state"


def _read_registry(registry_path: Path):
    """
    Read up to MAX_REGISTRY_ENTRIES lines off the tail of the registry.
    Skip un-parseable lines silently. Returns most-recent-first.
    """
    if not registry_path.exists():
        return []
    try:
        lines = registry_path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return []

    lines = lines[-MAX_REGISTRY_ENTRIES:]
    entries = []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            continue
    return entries


def _git(args, cwd: Path):
    """Run a git command with a short timeout. Return stdout text or None."""
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT_S,
        )
        if result.returncode != 0:
            return None
        return result.stdout
    except Exception:
        return None


def _gh_pr_state_for_branch(branch: str):
    """
    Return the highest-priority PR state for a branch:
      "MERGED" if any PR for this branch is merged
      "OPEN"   if any open PR exists
      "CLOSED" if there's only a closed-not-merged PR
      None     if no PR was found OR the call failed.
    """
    if not branch:
        return None
    try:
        result = subprocess.run(
            [
                "gh", "pr", "list",
                "--head", branch,
                "--state", "all",
                "--json", "state",
                "--limit", "5",
            ],
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT_S,
        )
        if result.returncode != 0:
            return None
        prs = json.loads(result.stdout or "[]")
        states = {pr.get("state") for pr in prs if isinstance(pr, dict)}
        if "MERGED" in states:
            return "MERGED"
        if "OPEN" in states:
            return "OPEN"
        if "CLOSED" in states:
            return "CLOSED"
        return None
    except Exception:
        return None


def _format_age(seconds: float) -> str:
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        return f"{int(seconds // 60)}m ago"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h ago"
    return f"{int(seconds // 86400)}d ago"


def _diff_summary(worktree: Path):
    """
    Return (lines_changed, files_changed) for the worktree's working tree
    (uncommitted + untracked changes vs HEAD). Returns (0, 0) on error.
    """
    porcelain = _git(["status", "--porcelain"], worktree) or ""
    files = sum(1 for line in porcelain.splitlines() if line.strip())

    # `git diff HEAD --shortstat` gives a one-line summary like
    #   " 3 files changed, 47 insertions(+), 12 deletions(-)"
    shortstat = _git(["diff", "HEAD", "--shortstat"], worktree) or ""
    lines = 0
    for token in shortstat.split(","):
        token = token.strip()
        if "insertion" in token:
            try:
                lines += int(token.split()[0])
            except Exception:
                pass
        elif "deletion" in token:
            try:
                lines += int(token.split()[0])
            except Exception:
                pass
    return lines, files


def _detect_orphans(project_root: Path, state_dir: Path, current_session_id: str):
    """
    Return a list of orphan dicts ready for rendering. At most
    MAX_OUTPUT_ENTRIES; deduped by agent_id (newest registry entry wins).
    """
    entries = _read_registry(state_dir / "agent-registry.jsonl")
    seen_agents = set()
    candidates = []

    for entry in entries:
        agent_id = entry.get("agent_id")
        if not agent_id or agent_id in seen_agents:
            continue
        seen_agents.add(agent_id)

        if entry.get("isolation") != "worktree":
            continue
        if entry.get("session_id") == current_session_id:
            # Same session — still alive, not an orphan.
            continue

        worktree_rel = entry.get("worktree_path") or ""
        if not worktree_rel:
            continue
        worktree = (project_root / worktree_rel).resolve()
        if not worktree.is_dir():
            continue

        lines_changed, files_changed = _diff_summary(worktree)
        if files_changed == 0:
            continue

        # Resolve current branch up-front so we can batch the gh calls.
        branch = (_git(["branch", "--show-current"], worktree) or "").strip()

        candidates.append({
            "entry": entry,
            "worktree": worktree,
            "lines": lines_changed,
            "files": files_changed,
            "branch": branch,
        })

        if len(candidates) >= MAX_OUTPUT_ENTRIES * 2:
            # Over-collect by 2x to leave headroom for PR-shipped filtering
            # below before truncating to the final cap.
            break

    if not candidates:
        return []

    # Parallel gh check: each unique branch → one call.
    unique_branches = list({c["branch"] for c in candidates if c["branch"]})
    pr_cache: dict[str, str | None] = {}
    if unique_branches:
        with ThreadPoolExecutor(max_workers=GH_POOL_SIZE) as pool:
            for branch, state in zip(
                unique_branches,
                pool.map(_gh_pr_state_for_branch, unique_branches),
            ):
                pr_cache[branch] = state

    orphans = []
    for c in candidates:
        pr_state = pr_cache.get(c["branch"])
        if pr_state == "MERGED":
            # Work shipped. Worktree is just leftover; not an orphan.
            continue
        try:
            mtime = c["worktree"].stat().st_mtime
            age_s = max(0.0, time.time() - mtime)
        except Exception:
            age_s = 0.0
        c["age_s"] = age_s
        c["pr_state"] = pr_state
        orphans.append(c)
        if len(orphans) >= MAX_OUTPUT_ENTRIES:
            break
    return orphans


def _render(orphans) -> str:
    if not orphans:
        return ""

    lines = []
    lines.append("<orphan-agents-detected>")
    lines.append(
        f"Found {len(orphans)} agent worktree"
        f"{'s' if len(orphans) != 1 else ''} from prior sessions with "
        f"uncommitted work:"
    )
    lines.append("")

    for i, o in enumerate(orphans, start=1):
        e = o["entry"]
        agent_id = e.get("agent_id", "")
        short = agent_id[:9] if agent_id else "?"
        desc = e.get("description") or "(no description)"
        worktree_rel = e.get("worktree_path") or ""
        brief_rel = e.get("brief_path") or ""
        first = e.get("brief_first_line") or ""
        pr_state = o.get("pr_state")
        branch = o.get("branch") or ""

        lines.append(f"{i}. agent-{short} — {desc}")
        lines.append(f"   worktree: {worktree_rel}")
        if branch:
            lines.append(f"   branch:   {branch}")
        lines.append(
            f"   diff:     {o['lines']} lines / {o['files']} files"
        )
        lines.append(f"   touched:  {_format_age(o['age_s'])}")
        if pr_state:
            lines.append(f"   pr state: {pr_state}")
        if brief_rel:
            preview = f' (first line: "{first}")' if first else ""
            lines.append(f"   brief:    {brief_rel}{preview}")
        lines.append("")

    lines.append(
        "To resurrect, ask Claude: \"resume orphaned agents\" — Claude "
        "can read the brief sidecars listed above and spawn continuation "
        "agents."
    )
    lines.append("</orphan-agents-detected>")
    return "\n".join(lines)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}

    try:
        current_session_id = payload.get("session_id") or ""

        project_root, state_dir = _resolve_paths()
        if not state_dir.exists():
            return  # no registry yet — nothing to do.

        orphans = _detect_orphans(project_root, state_dir, current_session_id)
        if not orphans:
            return  # don't pollute fresh sessions with empty reminders

        text = _render(orphans)
        if text:
            sys.stdout.write(text)
    except Exception:
        # Silent fail. SessionStart must never throw — a broken hook
        # would block every new session.
        return


if __name__ == "__main__":
    main()
