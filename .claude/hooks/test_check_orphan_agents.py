#!/usr/bin/env python3
"""
Unit tests for the orphan-agent hook system. No pytest, no external
deps — runnable as `python3 .claude/hooks/test_check_orphan_agents.py`.

Coverage:
  * record-agent-dispatch.py (PostToolUse) — synthesises a payload
    matching real Claude Code output, runs the hook in a tmp project,
    verifies registry + brief sidecar are created with correct content.
  * check-orphan-agents.py (SessionStart) — builds a fixture project
    with multiple worktree shapes (clean / dirty / missing /
    same-session / merged-PR via stub gh) and asserts the renderer
    emits exactly the expected entries.

We exercise both hooks as black-box subprocesses so the tests reflect
real invocation conditions (stdin/stdout/exit-code) and would catch
regressions in arg-parsing or process plumbing.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


HOOKS_DIR = Path(__file__).resolve().parent
RECORD_HOOK = HOOKS_DIR / "record-agent-dispatch.py"
ORPHAN_HOOK = HOOKS_DIR / "check-orphan-agents.py"


# ---------------------------------------------------------------------------
# Tiny test framework
# ---------------------------------------------------------------------------

_PASSED = 0
_FAILED = 0
_FAILURES = []


def expect(cond, label):
    global _PASSED, _FAILED
    if cond:
        _PASSED += 1
        print(f"  ok   {label}")
    else:
        _FAILED += 1
        _FAILURES.append(label)
        print(f"  FAIL {label}")


def run_hook(hook_path: Path, stdin_text: str, env_extra: dict | None = None,
             cwd: Path | None = None):
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    # Strip CLAUDE_PROJECT_DIR unless explicitly set, so the hook walks up
    # from cwd. (Some shells inherit it.)
    env.setdefault("CLAUDE_PROJECT_DIR", str(cwd) if cwd else "")
    proc = subprocess.run(
        ["python3", str(hook_path)],
        input=stdin_text,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(cwd) if cwd else None,
        timeout=10,
    )
    return proc


def make_fake_worktree(parent: Path, agent_id: str, dirty: bool = True,
                       branch: str = None):
    """
    Create a real git worktree under <parent>/.claude/worktrees/agent-<id>/
    so the hook's `git status` calls succeed. If dirty=True, add an
    uncommitted file. If branch is given, name the branch accordingly
    (else uses worktree-agent-<id>).
    """
    wt_root = parent / ".claude" / "worktrees" / f"agent-{agent_id}"
    wt_root.parent.mkdir(parents=True, exist_ok=True)

    # Initialise as a standalone git repo (worktree from a real parent
    # would be more accurate but adds a lot of test setup).
    subprocess.run(["git", "init", "--quiet", str(wt_root)], check=True)
    subprocess.run(
        ["git", "-C", str(wt_root), "config", "user.email", "t@t"], check=True
    )
    subprocess.run(
        ["git", "-C", str(wt_root), "config", "user.name", "t"], check=True
    )
    subprocess.run(
        ["git", "-C", str(wt_root), "config", "commit.gpgsign", "false"],
        check=True,
    )
    # Empty initial commit so HEAD exists (otherwise `git diff HEAD` fails).
    subprocess.run(
        ["git", "-C", str(wt_root), "commit", "--allow-empty",
         "-m", "init", "--quiet"],
        check=True,
    )
    if branch:
        subprocess.run(
            ["git", "-C", str(wt_root), "branch", "-M", branch], check=True
        )
    else:
        subprocess.run(
            ["git", "-C", str(wt_root),
             "branch", "-M", f"worktree-agent-{agent_id}"],
            check=True,
        )

    if dirty:
        (wt_root / "WIP.md").write_text("orphan work in progress\nmore work\n")
    return wt_root


def write_registry_entry(state_dir: Path, **fields):
    state_dir.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": "2026-05-03T00:00:00+00:00",
        "session_id": "parent-session",
        "agent_id": "deadbeef0001",
        "description": "test agent",
        "subagent_type": "general-purpose",
        "isolation": "worktree",
        "worktree_path": ".claude/worktrees/agent-deadbeef0001",
        "output_file": "/private/tmp/claude-501/x.output",
        "brief_path": ".claude/state/agent-briefs/deadbeef0001.md",
        "brief_first_line": "Agent fix the thing",
    }
    entry.update(fields)
    with (state_dir / "agent-registry.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")
    return entry


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def test_record_hook_writes_registry_and_brief():
    print("\n[test] record-agent-dispatch.py: writes registry + brief")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)

        payload = {
            "session_id": "session-aaa",
            "tool_name": "Agent",
            "tool_input": {
                "description": "Hero handle into trim panel",
                "subagent_type": "general-purpose",
                "isolation": "worktree",
                "prompt": "First line of the brief.\nSecond line.\n",
            },
            "tool_response": {
                "agentId": "abc1234567890",
                "output_file": "/tmp/output.jsonl",
            },
        }
        proc = run_hook(RECORD_HOOK, json.dumps(payload), cwd=project)
        expect(proc.returncode == 0, "exit 0")
        expect(proc.stdout == "", "no stdout")

        registry = project / ".claude" / "state" / "agent-registry.jsonl"
        expect(registry.exists(), "registry file exists")
        rows = registry.read_text().strip().splitlines()
        expect(len(rows) == 1, "one registry row")
        row = json.loads(rows[0])
        expect(row["agent_id"] == "abc1234567890", "agent_id captured")
        expect(row["session_id"] == "session-aaa", "session_id captured")
        expect(row["description"] == "Hero handle into trim panel",
               "description captured")
        expect(
            row["worktree_path"] == ".claude/worktrees/agent-abc1234567890",
            "worktree_path derived",
        )
        expect(row["brief_first_line"] == "First line of the brief.",
               "brief_first_line captured")

        brief = project / ".claude" / "state" / "agent-briefs" / "abc1234567890.md"
        expect(brief.exists(), "brief sidecar exists")
        expect(
            brief.read_text() == "First line of the brief.\nSecond line.\n",
            "brief sidecar content matches prompt",
        )


def test_record_hook_skips_non_worktree():
    print("\n[test] record-agent-dispatch.py: skips non-worktree agents")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        payload = {
            "session_id": "x",
            "tool_name": "Agent",
            "tool_input": {
                "description": "inline agent",
                "isolation": None,
                "prompt": "do work",
            },
            "tool_response": {"agentId": "ffff"},
        }
        proc = run_hook(RECORD_HOOK, json.dumps(payload), cwd=project)
        expect(proc.returncode == 0, "exit 0")
        registry = project / ".claude" / "state" / "agent-registry.jsonl"
        expect(not registry.exists(), "registry not created for non-worktree")


def test_record_hook_extracts_from_text_response():
    print("\n[test] record-agent-dispatch.py: regex-fallback agentId extract")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)

        # Real Claude Code shape: the textual response contains the
        # agentId line. Don't supply agentId structurally.
        payload = {
            "session_id": "session-bbb",
            "tool_name": "Agent",
            "tool_input": {
                "description": "fallback test",
                "isolation": "worktree",
                "prompt": "Do the thing.",
            },
            "tool_response": {
                "content": [
                    {
                        "type": "text",
                        "text": (
                            "Async agent launched successfully.\n"
                            "agentId: feedface1234 (internal ID)\n"
                            "output_file: /tmp/x.out\n"
                        ),
                    }
                ]
            },
        }
        proc = run_hook(RECORD_HOOK, json.dumps(payload), cwd=project)
        expect(proc.returncode == 0, "exit 0")
        registry = project / ".claude" / "state" / "agent-registry.jsonl"
        expect(registry.exists(), "registry created from textual response")
        row = json.loads(registry.read_text().strip())
        expect(row["agent_id"] == "feedface1234",
               "agent_id extracted from text")
        expect(row["output_file"] == "/tmp/x.out",
               "output_file extracted from text")


def test_record_hook_silent_on_garbage():
    print("\n[test] record-agent-dispatch.py: silent on garbage stdin")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        proc = run_hook(RECORD_HOOK, "{not json", cwd=project)
        expect(proc.returncode == 0, "exit 0 on bad json")
        proc = run_hook(RECORD_HOOK, "", cwd=project)
        expect(proc.returncode == 0, "exit 0 on empty stdin")


def test_orphan_hook_dirty_worktree_emitted():
    print("\n[test] check-orphan-agents.py: dirty worktree emitted")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        state = project / ".claude" / "state"

        # Build the worktree first, because the orphan check inspects
        # the actual filesystem.
        agent_id = "abcd0001"
        make_fake_worktree(project, agent_id, dirty=True)
        write_registry_entry(
            state,
            session_id="prior-session",
            agent_id=agent_id,
            worktree_path=f".claude/worktrees/agent-{agent_id}",
            description="dirty orphan",
        )

        # Stub `gh` so we don't hit the network. Also returns no PRs.
        bin_dir = project / "_bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho '[]'\nexit 0\n")
        (bin_dir / "gh").chmod(0o755)

        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
        payload = {"session_id": "current-session", "hook_event_name": "SessionStart"}
        proc = run_hook(ORPHAN_HOOK, json.dumps(payload), env_extra=env, cwd=project)

        expect(proc.returncode == 0, "exit 0")
        expect("orphan-agents-detected" in proc.stdout,
               "system reminder emitted")
        expect("dirty orphan" in proc.stdout, "description shown")
        expect(f"agent-{agent_id[:9]}" in proc.stdout, "short agent id shown")


def test_orphan_hook_clean_worktree_silent():
    print("\n[test] check-orphan-agents.py: clean worktree NOT emitted")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        state = project / ".claude" / "state"

        agent_id = "abcd0002"
        make_fake_worktree(project, agent_id, dirty=False)
        write_registry_entry(
            state,
            session_id="prior-session",
            agent_id=agent_id,
            worktree_path=f".claude/worktrees/agent-{agent_id}",
            description="clean worktree",
        )

        bin_dir = project / "_bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho '[]'\nexit 0\n")
        (bin_dir / "gh").chmod(0o755)

        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
        payload = {"session_id": "current-session"}
        proc = run_hook(ORPHAN_HOOK, json.dumps(payload), env_extra=env, cwd=project)
        expect(proc.returncode == 0, "exit 0")
        expect(proc.stdout == "", "no output for clean worktree")


def test_orphan_hook_merged_pr_filtered():
    print("\n[test] check-orphan-agents.py: merged-PR worktree filtered out")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        state = project / ".claude" / "state"

        agent_id = "abcd0003"
        make_fake_worktree(project, agent_id, dirty=True)
        write_registry_entry(
            state,
            session_id="prior-session",
            agent_id=agent_id,
            worktree_path=f".claude/worktrees/agent-{agent_id}",
            description="shipped already",
        )

        # Stub gh to report a MERGED PR for any branch.
        bin_dir = project / "_bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(
            '#!/bin/sh\necho \'[{"state":"MERGED"}]\'\nexit 0\n'
        )
        (bin_dir / "gh").chmod(0o755)

        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
        payload = {"session_id": "current-session"}
        proc = run_hook(ORPHAN_HOOK, json.dumps(payload), env_extra=env, cwd=project)
        expect(proc.returncode == 0, "exit 0")
        expect(proc.stdout == "", "merged-PR worktree suppressed")


def test_orphan_hook_missing_worktree_skipped():
    print("\n[test] check-orphan-agents.py: missing worktree skipped")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        state = project / ".claude" / "state"

        # Registry refers to a worktree that doesn't exist.
        write_registry_entry(
            state,
            session_id="prior-session",
            agent_id="ghosted",
            worktree_path=".claude/worktrees/agent-ghosted",
            description="gone agent",
        )

        bin_dir = project / "_bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho '[]'\nexit 0\n")
        (bin_dir / "gh").chmod(0o755)

        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
        payload = {"session_id": "current-session"}
        proc = run_hook(ORPHAN_HOOK, json.dumps(payload), env_extra=env, cwd=project)
        expect(proc.returncode == 0, "exit 0")
        expect(proc.stdout == "", "no output for missing worktree")


def test_orphan_hook_same_session_filtered():
    print("\n[test] check-orphan-agents.py: same-session agent ignored")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        state = project / ".claude" / "state"

        agent_id = "abcd0004"
        make_fake_worktree(project, agent_id, dirty=True)
        write_registry_entry(
            state,
            session_id="MY-CURRENT-SESSION",
            agent_id=agent_id,
            worktree_path=f".claude/worktrees/agent-{agent_id}",
            description="still mine",
        )

        bin_dir = project / "_bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text("#!/bin/sh\necho '[]'\nexit 0\n")
        (bin_dir / "gh").chmod(0o755)

        env = {"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
        payload = {"session_id": "MY-CURRENT-SESSION"}
        proc = run_hook(ORPHAN_HOOK, json.dumps(payload), env_extra=env, cwd=project)
        expect(proc.returncode == 0, "exit 0")
        expect(proc.stdout == "", "same-session agent treated as still-alive")


def test_orphan_hook_no_registry_silent():
    print("\n[test] check-orphan-agents.py: no registry → silent")
    with tempfile.TemporaryDirectory() as tmp:
        project = Path(tmp) / "proj"
        (project / ".claude").mkdir(parents=True)
        payload = {"session_id": "current-session"}
        proc = run_hook(ORPHAN_HOOK, json.dumps(payload), cwd=project)
        expect(proc.returncode == 0, "exit 0 with no registry")
        expect(proc.stdout == "", "silent with no registry")


# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------

def main() -> int:
    if not RECORD_HOOK.exists() or not ORPHAN_HOOK.exists():
        print(f"Hooks not found at {HOOKS_DIR}", file=sys.stderr)
        return 2

    test_record_hook_writes_registry_and_brief()
    test_record_hook_skips_non_worktree()
    test_record_hook_extracts_from_text_response()
    test_record_hook_silent_on_garbage()
    test_orphan_hook_dirty_worktree_emitted()
    test_orphan_hook_clean_worktree_silent()
    test_orphan_hook_merged_pr_filtered()
    test_orphan_hook_missing_worktree_skipped()
    test_orphan_hook_same_session_filtered()
    test_orphan_hook_no_registry_silent()

    print(f"\n{'='*50}")
    print(f"PASSED: {_PASSED}   FAILED: {_FAILED}")
    if _FAILURES:
        print("\nFailures:")
        for f in _FAILURES:
            print(f"  - {f}")
    return 0 if _FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
