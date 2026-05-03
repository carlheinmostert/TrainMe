#!/usr/bin/env python3
"""
PostToolUse hook for the Agent tool — records every isolated-worktree
sub-agent dispatch into a per-developer registry so we can later detect
orphans (agents whose parent session died with their work uncommitted).

Background (2026-05-03): Carl just lost a session that had 4 running
background sub-agents. Each was happily working in its own worktree under
.claude/worktrees/agent-<id>/, but when the parent crashed the agents
died too — leaving uncommitted work scattered across worktrees with no
discoverable trail back to "what was each agent doing?". Recovery took
30+ minutes of grepping through ~/.claude/projects/<...>.jsonl
transcripts to match agentId -> worktree -> brief. The companion
SessionStart hook (`check-orphan-agents.py`) reads what we write here.

What this hook does:
  1. Pulls the Agent tool's input + response off the PostToolUse stdin
     payload. We only care about `isolation: "worktree"` calls — those
     are the ones that leave a detectable filesystem footprint.
  2. Appends a single JSON line to `.claude/state/agent-registry.jsonl`
     with: timestamp, parent session_id, agent_id, description,
     subagent_type, isolation, worktree path, output_file path, and a
     pointer to the brief sidecar.
  3. Writes the full agent prompt to a sidecar file at
     `.claude/state/agent-briefs/<agent_id>.md` so the SessionStart
     hook (and Claude on resume) can show it without having to read
     the bloated transcript.

Why the brief sidecar instead of inlining?
  Briefs are typically 2-10kB; if we inline them, the registry quickly
  becomes too big for the SessionStart hook to scan in <500ms.

Schema notes (Claude Code as of 2026-05-03):
  PostToolUse stdin payload includes `tool_name`, `tool_input` (always),
  and a tool-response field whose name has varied across Claude Code
  versions — we accept any of `tool_response` / `tool_output` /
  `toolUseResult`. The agent ID may also be embedded in the stringified
  output text ("agentId: <hex>"). We try each in turn.

Safety: any exception → exit 0 silently. A broken hook MUST NEVER
block Agent dispatches.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def _resolve_state_dir() -> Path:
    """
    Return the project's `.claude/state/` directory, creating it if needed.

    The hook runs with cwd set to the session's working directory. We walk
    upward looking for a `.claude/` sibling so the hook works correctly
    from sub-paths and from inside agent worktrees alike. If nothing is
    found, fall back to `<cwd>/.claude/state/`.
    """
    cwd = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()
    for candidate in [cwd, *cwd.parents]:
        if (candidate / ".claude").is_dir():
            return candidate / ".claude" / "state"
    return cwd / ".claude" / "state"


# Match the agentId line that Claude Code emits in the textual tool
# response. Captures hex IDs of any reasonable length.
_AGENT_ID_LINE_RE = re.compile(r"agentId:\s*([0-9a-fA-F]{6,})")
_OUTPUT_FILE_LINE_RE = re.compile(r"output_file:\s*(\S+)")


def _stringify(node) -> str:
    """Coerce a tool-response sub-tree into a single string for regex match."""
    if isinstance(node, str):
        return node
    if isinstance(node, dict):
        for key in ("text", "output", "content"):
            if key in node:
                return _stringify(node[key])
        return json.dumps(node)
    if isinstance(node, list):
        return "\n".join(_stringify(x) for x in node)
    return ""


def _extract_response(payload: dict):
    """
    Return (agent_id, output_file) extracted from the PostToolUse payload.

    Accepts multiple field-name shapes for forward-compatibility:
      * `tool_response` (current docs example)
      * `tool_output` (older drafts)
      * `toolUseResult` (matches the on-disk transcript shape)
    Falls back to regex-scanning the stringified content for the agentId
    text Claude Code emits in the user-visible response.
    """
    raw = (
        payload.get("tool_response")
        or payload.get("tool_output")
        or payload.get("toolUseResult")
        or payload.get("response")
    )

    agent_id = None
    output_file = None

    if isinstance(raw, dict):
        agent_id = raw.get("agentId") or raw.get("agent_id")
        output_file = raw.get("output_file") or raw.get("outputFile")

    blob = _stringify(raw) if raw is not None else ""
    if not agent_id and blob:
        m = _AGENT_ID_LINE_RE.search(blob)
        if m:
            agent_id = m.group(1)
    if not output_file and blob:
        m = _OUTPUT_FILE_LINE_RE.search(blob)
        if m:
            output_file = m.group(1)

    return agent_id, output_file


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    try:
        if payload.get("tool_name") != "Agent":
            return

        tool_input = payload.get("tool_input") or {}
        if tool_input.get("isolation") != "worktree":
            # Only track worktree-isolated agents. Non-isolated agents
            # share the parent cwd and leave no orphan filesystem state.
            return

        agent_id, output_file = _extract_response(payload)
        if not agent_id:
            # No agent ID -> nothing to register. Silent exit.
            return

        prompt = tool_input.get("prompt") or ""
        description = tool_input.get("description") or "(no description)"
        subagent_type = tool_input.get("subagent_type") or ""
        session_id = payload.get("session_id") or ""

        worktree_rel = f".claude/worktrees/agent-{agent_id}"

        state_dir = _resolve_state_dir()
        briefs_dir = state_dir / "agent-briefs"
        state_dir.mkdir(parents=True, exist_ok=True)
        briefs_dir.mkdir(parents=True, exist_ok=True)

        brief_path_rel = f".claude/state/agent-briefs/{agent_id}.md"
        try:
            (briefs_dir / f"{agent_id}.md").write_text(prompt, encoding="utf-8")
        except Exception:
            # Brief-write failure is recoverable — the registry entry
            # still carries the description, which is enough for orphan
            # detection.
            pass

        brief_first_line = ""
        for line in prompt.splitlines():
            stripped = line.strip()
            if stripped:
                brief_first_line = stripped[:200]
                break

        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "session_id": session_id,
            "agent_id": agent_id,
            "description": description,
            "subagent_type": subagent_type,
            "isolation": "worktree",
            "worktree_path": worktree_rel,
            "output_file": output_file or "",
            "brief_path": brief_path_rel,
            "brief_first_line": brief_first_line,
        }

        registry = state_dir / "agent-registry.jsonl"
        with registry.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

    except Exception:
        # Any failure -> silent exit. A broken hook must never block
        # Agent dispatches.
        return


if __name__ == "__main__":
    main()
