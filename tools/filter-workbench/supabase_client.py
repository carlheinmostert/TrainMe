"""Thin Supabase REST client for the filter workbench.

We only need two things from Supabase:

1. List published plans together with their exercises (one round-trip).
2. Download a given exercise's video bytes from public storage.

We use PostgREST directly (``GET /rest/v1/plans?...``) rather than a
heavyweight SDK. The anon key is publishable, row-level security gates
access server-side.

Config is read from the environment, falling back to the same URL and
publishable key that ship in ``app/lib/config.dart``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

# Defaults mirror app/lib/config.dart so the workbench works out of the
# box against Carl's production project.
DEFAULT_SUPABASE_URL = "https://yrwcofhovrcydootivjx.supabase.co"
DEFAULT_SUPABASE_ANON_KEY = "sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3"

SUPABASE_URL = os.environ.get("SUPABASE_URL", DEFAULT_SUPABASE_URL).rstrip("/")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", DEFAULT_SUPABASE_ANON_KEY)

# Workbench-local cache directory for downloaded videos. Gitignored.
CACHE_DIR = Path(__file__).parent / "cache"

_REQUEST_TIMEOUT_SECONDS = 30
_DOWNLOAD_TIMEOUT_SECONDS = 120


@dataclass(frozen=True)
class Exercise:
    """A single exercise on a published plan."""

    id: str
    plan_id: str
    name: str | None
    media_url: str | None
    media_type: str  # 'photo' | 'video' | 'rest'
    position: int


@dataclass(frozen=True)
class Plan:
    """A published plan with its exercises."""

    id: str
    client_name: str
    title: str | None
    sent_at: str | None
    exercises: list[Exercise]

    @property
    def label(self) -> str:
        """Dropdown-ready label."""
        title = self.title or "(untitled plan)"
        return f"{self.client_name} — {title}"

    def video_exercises(self) -> list[Exercise]:
        """Return exercises whose media_type == 'video' with a URL."""
        return [
            e
            for e in self.exercises
            if e.media_type == "video" and e.media_url
        ]


def _headers() -> dict[str, str]:
    return {
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
        "Accept": "application/json",
    }


def fetch_published_plans() -> list[Plan]:
    """Return every published plan (``sent_at IS NOT NULL``) with exercises.

    Sorted newest-first so the dropdown shows recent work on top.
    """
    url = f"{SUPABASE_URL}/rest/v1/plans"
    params = {
        "select": "id,client_name,title,sent_at,exercises(id,plan_id,name,media_url,media_type,position)",
        "sent_at": "not.is.null",
        "order": "sent_at.desc",
    }
    resp = requests.get(
        url,
        headers=_headers(),
        params=params,
        timeout=_REQUEST_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    raw: list[dict[str, Any]] = resp.json()
    plans: list[Plan] = []
    for row in raw:
        exercises = [
            Exercise(
                id=str(e["id"]),
                plan_id=str(e.get("plan_id") or row["id"]),
                name=e.get("name"),
                media_url=e.get("media_url"),
                media_type=str(e["media_type"]),
                position=int(e.get("position") or 0),
            )
            for e in (row.get("exercises") or [])
        ]
        exercises.sort(key=lambda e: e.position)
        plans.append(
            Plan(
                id=str(row["id"]),
                client_name=str(row["client_name"]),
                title=row.get("title"),
                sent_at=row.get("sent_at"),
                exercises=exercises,
            )
        )
    return plans


def ensure_cache_dir() -> Path:
    """Create the cache directory if needed, returning its path."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return CACHE_DIR


def cached_video_path(exercise: Exercise) -> Path:
    """Return the on-disk path where the exercise video is cached."""
    ensure_cache_dir()
    # media_url extensions are not always present; default to .mp4.
    suffix = ".mp4"
    if exercise.media_url:
        tail = exercise.media_url.rsplit("?", 1)[0].rsplit(".", 1)
        if len(tail) == 2 and 1 <= len(tail[1]) <= 5:
            suffix = "." + tail[1].lower()
    return CACHE_DIR / f"{exercise.id}{suffix}"


def download_video(exercise: Exercise) -> Path:
    """Download ``exercise.media_url`` into the cache, return the path.

    If the file already exists and is non-empty, the download is
    skipped (cache hit).
    """
    if not exercise.media_url:
        raise ValueError(
            f"Exercise {exercise.id!r} has no media_url, cannot download."
        )
    dest = cached_video_path(exercise)
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    with requests.get(
        exercise.media_url,
        stream=True,
        timeout=_DOWNLOAD_TIMEOUT_SECONDS,
    ) as resp:
        resp.raise_for_status()
        tmp = dest.with_suffix(dest.suffix + ".part")
        with tmp.open("wb") as fh:
            for chunk in resp.iter_content(chunk_size=1 << 16):
                if chunk:
                    fh.write(chunk)
        tmp.replace(dest)
    return dest
