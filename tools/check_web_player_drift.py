#!/usr/bin/env python3
"""Fail if mirrored web-player bundle files drift."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

FILES = ("index.html", "app.js", "api.js", "styles.css")


def sha256_hex(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    source_dir = repo_root / "web-player"
    mirror_dir = repo_root / "app" / "assets" / "web-player"

    missing: list[str] = []
    drift: list[tuple[str, str, str]] = []

    if not source_dir.is_dir():
        print(f"ERROR: source directory missing: {source_dir}")
        return 1
    if not mirror_dir.is_dir():
        print(f"ERROR: mirror directory missing: {mirror_dir}")
        return 1

    for name in FILES:
        source_file = source_dir / name
        mirror_file = mirror_dir / name

        if not source_file.is_file():
            missing.append(f"missing source file: {source_file}")
            continue
        if not mirror_file.is_file():
            missing.append(f"missing mirror file: {mirror_file}")
            continue

        source_hash = sha256_hex(source_file)
        mirror_hash = sha256_hex(mirror_file)
        if source_hash != mirror_hash:
            drift.append((name, source_hash, mirror_hash))

    if missing:
        print("ERROR: web-player drift check failed due to missing files:")
        for item in missing:
            print(f"- {item}")
        return 1

    if drift:
        print("ERROR: web-player drift detected between source and mirror:")
        for name, source_hash, mirror_hash in drift:
            print(f"- {name}")
            print(f"  source (web-player/{name}): {source_hash}")
            print(f"  mirror (app/assets/web-player/{name}): {mirror_hash}")
        print("Fix: run `dart run app/tool/sync_web_player_bundle.dart` from repo root.")
        return 1

    print("OK: web-player mirrored bundle is in sync.")
    for name in FILES:
        file_hash = sha256_hex(source_dir / name)
        print(f"- {name}: {file_hash}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
