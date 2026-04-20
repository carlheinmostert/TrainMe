#!/usr/bin/env python3
"""
PreToolUse hook for the Agent tool — stops isolated-worktree sub-agents
from leaking writes into the main repo.

Background (2026-04-20): when an agent is spawned with
`isolation: "worktree"`, Claude Code creates a git worktree under
.claude/worktrees/agent-<id>/ and spawns the sub-agent with that as cwd.
The agent is supposed to read/write files via paths relative to its
worktree. In practice, briefs that reference absolute paths like
`/Users/chm/dev/TrainMe/app/lib/foo.dart` seduce agents into using those
absolute paths for their OWN file operations — so they write back to
the MAIN repo's working tree instead of their isolated worktree. Result:
stray dirty state in main, merge conflicts across parallel agents,
sometimes silent data loss. We hit this across all four parallel agents
in one session before figuring out the mechanism.

This hook fires before every Agent tool call. When the call is for the
`Agent` tool AND `isolation == "worktree"`:

  1. Strips `/Users/chm/dev/TrainMe/` absolute prefixes from the prompt
     so repo-relative paths remain (`app/lib/foo.dart` instead of
     `/Users/chm/dev/TrainMe/app/lib/foo.dart`).
  2. Prepends a CRITICAL worktree-isolation banner so even if an
     absolute path slips through, the agent reads it as "reference
     only, resolve against cwd".

Safety: any exception → exit 0 without emitting output. A broken hook
MUST NEVER block Agent invocations.
"""
from __future__ import annotations

import json
import sys


REPO_ROOT = "/Users/chm/dev/TrainMe/"

BANNER = (
    "CRITICAL — you are running in an isolated git worktree. Every file "
    "operation MUST use repo-relative paths (e.g. `app/lib/foo.dart`). "
    "NEVER use absolute paths starting with `/Users/chm/dev/TrainMe/...` "
    "— those resolve to the main repo tree and cause merge conflicts + "
    "leak dirty state across agents. If the brief below references any "
    "absolute path, treat it as reference only; do your own reads/writes "
    "against your current working directory.\n\n"
    "---\n\n"
)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return  # unparseable stdin → pass through unchanged

    try:
        if payload.get("tool_name") != "Agent":
            return

        tool_input = payload.get("tool_input") or {}
        if tool_input.get("isolation") != "worktree":
            return

        prompt = tool_input.get("prompt")
        if not isinstance(prompt, str) or not prompt:
            return

        # Strip the repo-root prefix. Any `/Users/chm/dev/TrainMe/…` token
        # becomes the bare relative path (e.g. `app/lib/foo.dart`).
        stripped = prompt.replace(REPO_ROOT, "")

        new_prompt = BANNER + stripped
        if new_prompt == prompt:
            return  # nothing to change

        updated_input = {**tool_input, "prompt": new_prompt}

        out = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "updatedInput": updated_input,
            },
        }
        sys.stdout.write(json.dumps(out))
    except Exception:
        # Any failure → pass through unchanged. A hook that blocks
        # Agent invocations is strictly worse than one that silently
        # does nothing.
        return


if __name__ == "__main__":
    main()
