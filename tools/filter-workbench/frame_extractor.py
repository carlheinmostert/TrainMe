"""Extract evenly-spaced JPEG frames from a video and cache them.

The Streamlit UI picks a single frame to filter at a time, so we don't
need the whole video in memory. We pull N frames spread across the
video's duration, cache them as JPEGs next to the downloaded video,
and return ``(frame_index, cached_path)`` pairs.

Subsequent calls with the same exercise id hit the cache and skip the
decode entirely — important because OpenCV's ``VideoCapture`` is
noticeably slow on H.264/HEVC in Python.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2

DEFAULT_FRAME_COUNT = 30
CACHE_DIR = Path(__file__).parent / "cache"


@dataclass(frozen=True)
class ExtractedFrame:
    """A single frame pulled from a video and written to disk."""

    index: int  # 0-based index into the N-frame slice we pulled
    source_frame: int  # 0-based frame index within the source video
    path: Path


def _frame_path(exercise_id: str, index: int) -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return CACHE_DIR / f"{exercise_id}_frame_{index:02d}.jpg"


def _all_cached(exercise_id: str, count: int) -> list[Path] | None:
    paths = [_frame_path(exercise_id, i) for i in range(count)]
    if all(p.exists() and p.stat().st_size > 0 for p in paths):
        return paths
    return None


def extract_frames(
    video_path: Path,
    exercise_id: str,
    count: int = DEFAULT_FRAME_COUNT,
) -> list[ExtractedFrame]:
    """Return ``count`` evenly-spaced frames from ``video_path``.

    Frames are cached on disk as JPEGs keyed by ``exercise_id`` so the
    extraction only runs once per clip.

    :raises FileNotFoundError: if the video cannot be opened.
    :raises RuntimeError: if the video has zero readable frames.
    """
    if count <= 0:
        raise ValueError("count must be >= 1")
    video_path = Path(video_path)
    if not video_path.exists():
        raise FileNotFoundError(f"Video not found: {video_path}")

    cached = _all_cached(exercise_id, count)
    if cached is not None:
        # Reuse cache; source_frame cannot be recovered cheaply so we
        # reuse the requested index. Good enough for UI display.
        return [
            ExtractedFrame(index=i, source_frame=i, path=p)
            for i, p in enumerate(cached)
        ]

    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise FileNotFoundError(f"cv2.VideoCapture could not open: {video_path}")
    try:
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        if total <= 0:
            # Some containers report 0; fall back to reading until EOF.
            total = _count_frames_by_read(cap)
            cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        if total <= 0:
            raise RuntimeError(
                f"Video {video_path} has no readable frames."
            )

        # Pick ``count`` evenly-spaced indices in [0, total-1].
        if count == 1:
            picks = [total // 2]
        else:
            picks = [
                int(round(i * (total - 1) / (count - 1))) for i in range(count)
            ]
        frames: list[ExtractedFrame] = []
        for out_idx, src_idx in enumerate(picks):
            cap.set(cv2.CAP_PROP_POS_FRAMES, src_idx)
            ok, frame_bgr = cap.read()
            if not ok or frame_bgr is None:
                # Fallback: try re-seeking a few frames earlier.
                cap.set(cv2.CAP_PROP_POS_FRAMES, max(0, src_idx - 2))
                ok, frame_bgr = cap.read()
            if not ok or frame_bgr is None:
                continue
            dest = _frame_path(exercise_id, out_idx)
            cv2.imwrite(str(dest), frame_bgr)
            frames.append(
                ExtractedFrame(index=out_idx, source_frame=src_idx, path=dest)
            )
        if not frames:
            raise RuntimeError(
                f"Failed to extract any frames from {video_path}."
            )
        return frames
    finally:
        cap.release()


def _count_frames_by_read(cap: cv2.VideoCapture) -> int:
    """Fallback frame counter for containers that lie about length."""
    n = 0
    while True:
        ok = cap.grab()
        if not ok:
            break
        n += 1
    return n
