#!/usr/bin/env python3
"""Enforce Supabase data-access seams across surfaces.

This guard blocks *new* direct Supabase usage outside approved seam files.
Existing carve-outs are tracked in tools/data_access_seam_exceptions.json.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parent.parent
EXCEPTIONS_PATH = REPO_ROOT / "tools" / "data_access_seam_exceptions.json"


@dataclass(frozen=True)
class Rule:
    key: str
    root: Path
    include_suffixes: tuple[str, ...]
    regex: re.Pattern[str]
    allowed_files: set[Path]


RULES: tuple[Rule, ...] = (
    Rule(
        key="flutter_direct_supabase_client",
        root=REPO_ROOT / "app" / "lib",
        include_suffixes=(".dart",),
        regex=re.compile(r"\bSupabase\.instance\.client\b"),
        allowed_files={REPO_ROOT / "app" / "lib" / "services" / "api_client.dart"},
    ),
    Rule(
        key="web_player_direct_rest",
        root=REPO_ROOT / "web-player",
        include_suffixes=(".js",),
        regex=re.compile(r"/rest/v1/"),
        allowed_files={REPO_ROOT / "web-player" / "api.js"},
    ),
    Rule(
        key="web_portal_direct_supabase_ops",
        root=REPO_ROOT / "web-portal" / "src",
        include_suffixes=(".ts", ".tsx"),
        regex=re.compile(r"\b(?:this\.)?supabase\s*\.\s*(?:from|rpc|storage)\s*\("),
        allowed_files={REPO_ROOT / "web-portal" / "src" / "lib" / "supabase" / "api.ts"},
    ),
)


def _is_comment_line(line: str) -> bool:
    stripped = line.strip()
    return (
        not stripped
        or stripped.startswith("//")
        or stripped.startswith("/*")
        or stripped.startswith("*")
        or stripped.startswith("*/")
        or stripped.startswith("///")
    )


def _iter_files(root: Path, suffixes: Iterable[str]) -> Iterable[Path]:
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in suffixes:
            continue
        yield path


def _load_exceptions() -> set[str]:
    if not EXCEPTIONS_PATH.exists():
        return set()
    raw = json.loads(EXCEPTIONS_PATH.read_text())
    return set(raw.get("allowed_violations", []))


def _rel(path: Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def main() -> int:
    allowed = _load_exceptions()
    seen: set[str] = set()
    violations: list[str] = []

    for rule in RULES:
        for path in _iter_files(rule.root, rule.include_suffixes):
            if path in rule.allowed_files:
                continue
            try:
                lines = path.read_text().splitlines()
            except UnicodeDecodeError:
                continue
            for idx, line in enumerate(lines, start=1):
                if _is_comment_line(line):
                    continue
                if not rule.regex.search(line):
                    continue
                key = f"{rule.key}|{_rel(path)}|{idx}|{line.strip()}"
                seen.add(key)
                if key not in allowed:
                    violations.append(key)

    stale = sorted(allowed - seen)
    if violations:
        print("ERROR: Found new data-access seam violations:\n")
        for item in sorted(violations):
            print(f"- {item}")
        if stale:
            print("\nNote: Some allowlist entries are stale and can be removed:")
            for item in stale:
                print(f"- {item}")
        return 1

    print("OK: No new data-access seam violations.")
    if stale:
        print("\nStale allowlist entries detected (safe to remove):")
        for item in stale:
            print(f"- {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
