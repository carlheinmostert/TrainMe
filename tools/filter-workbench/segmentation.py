"""MediaPipe image-segmentation wrapper + two-zone compositor.

The on-device iOS pipeline runs a person-segmentation pass (Vision
framework) and then renders two zones differently:

- **Body pixels** use the filter output at full strength (crisp lines).
- **Background pixels** are dimmed so equipment + background edges fade
  out to ~35% strength. This stops the frame from looking like a noisy
  etching and keeps the client's focus on the body.

This module recreates that behaviour in Python using MediaPipe's
`ImageSegmenter` task (the modern Tasks API that replaced the legacy
`mp.solutions.selfie_segmentation` module). The selfie-segmenter
``.tflite`` model is auto-downloaded on first use and cached under
``cache/`` — no manual setup required.

The mask will not be pixel-identical to iOS Vision's output — different
model architectures — but the resulting look is close enough for tuning
intuition.

Import is lazy: MediaPipe is a heavy dependency, so we only load it the
first time ``get_mask`` is called. That keeps the "segmentation off"
code path fast to boot.
"""

from __future__ import annotations

import os
import threading
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import requests


# The ``selfie_segmenter`` task model matches the legacy
# ``model_selection=1`` general (full-body) behaviour most closely.
# Hosted by Google on their public model CDN; ~5-10 MB download.
_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/image_segmenter/"
    "selfie_segmenter/float16/latest/selfie_segmenter.tflite"
)
_MODEL_FILENAME = "selfie_segmenter.tflite"

# Cache sits beside this module so the path is stable regardless of the
# caller's cwd (Streamlit, CLI, or pytest all resolve to the same spot).
_CACHE_DIR = Path(__file__).resolve().parent / "cache"

# MediaPipe is imported lazily. These module-level caches keep the
# segmenter instance warm across Streamlit reruns.
_segmenter: Any = None
_segmenter_lock = threading.Lock()


def _ensure_model() -> Path:
    """Download the selfie-segmenter ``.tflite`` if not already cached.

    :returns: Absolute path to the cached model file.
    :raises RuntimeError: On network failure with a human-readable hint.
    """
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    model_path = _CACHE_DIR / _MODEL_FILENAME
    if model_path.exists() and model_path.stat().st_size > 0:
        return model_path

    tmp_path = model_path.with_suffix(model_path.suffix + ".part")
    try:
        with requests.get(_MODEL_URL, stream=True, timeout=60) as response:
            response.raise_for_status()
            with open(tmp_path, "wb") as fh:
                for chunk in response.iter_content(chunk_size=64 * 1024):
                    if chunk:
                        fh.write(chunk)
        os.replace(tmp_path, model_path)
    except requests.RequestException as exc:  # pragma: no cover - network
        # Clean up a half-written file so the next run retries from scratch.
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise RuntimeError(
            f"Failed to download MediaPipe selfie_segmenter model from "
            f"{_MODEL_URL}. Check your network connection and retry. "
            f"Underlying error: {exc!s}"
        ) from exc
    return model_path


def _get_segmenter() -> Any:
    """Return a cached MediaPipe ``ImageSegmenter`` instance.

    Raises :class:`RuntimeError` with a helpful hint if mediapipe is not
    installed — the Streamlit app catches this and shows a friendly
    install command.
    """
    global _segmenter
    if _segmenter is not None:
        return _segmenter
    with _segmenter_lock:
        if _segmenter is not None:
            return _segmenter
        try:
            # The Tasks API lives under ``mediapipe.tasks`` in recent
            # MediaPipe releases. The legacy ``mp.solutions.*`` modules
            # were removed in 0.10.14+, so we use the modern path.
            from mediapipe.tasks import python as mp_python  # type: ignore
            from mediapipe.tasks.python import vision  # type: ignore
        except ImportError as exc:  # pragma: no cover - import-time error
            raise RuntimeError(
                "mediapipe (Tasks API) is not installed or is too old. "
                "Run: pip install -r tools/filter-workbench/requirements.txt"
            ) from exc

        model_path = _ensure_model()
        base_options = mp_python.BaseOptions(model_asset_path=str(model_path))
        options = vision.ImageSegmenterOptions(
            base_options=base_options,
            running_mode=vision.RunningMode.IMAGE,
            # ``output_category_mask=True`` gives us a uint8 mask where
            # each pixel is the argmax class index. For the selfie
            # segmenter that's 0 = background, 1 = foreground (person).
            output_category_mask=True,
            output_confidence_masks=False,
        )
        _segmenter = vision.ImageSegmenter.create_from_options(options)
        return _segmenter


def get_mask(rgb_frame: np.ndarray, feather_radius: int = 5) -> np.ndarray:
    """Return a soft-edged person mask for ``rgb_frame``.

    :param rgb_frame: ``(H, W, 3)`` uint8 RGB image (NOT BGR).
    :param feather_radius: Half-width of the Gaussian blur applied to
        the raw mask to soften the edges. Must be >= 0.
    :returns: ``(H, W)`` uint8 mask where 255 = body, 0 = background,
        and values in between along the feathered edge.
    """
    if rgb_frame.ndim != 3 or rgb_frame.shape[2] != 3:
        raise ValueError(
            f"Expected (H, W, 3) RGB frame, got shape {rgb_frame.shape!r}."
        )
    # Import lazily so the heavy mediapipe import only happens once we
    # actually need it. Mirrors the segmenter-caching pattern below.
    import mediapipe as mp  # type: ignore

    segmenter = _get_segmenter()

    # MediaPipe expects a contiguous uint8 SRGB buffer. ``np.ascontiguousarray``
    # is a no-op for already-contiguous frames (the common case) and a cheap
    # copy otherwise.
    frame = np.ascontiguousarray(rgb_frame, dtype=np.uint8)
    mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame)
    result = segmenter.segment(mp_image)

    category_mask = result.category_mask
    if category_mask is None:
        return np.zeros(rgb_frame.shape[:2], dtype=np.uint8)

    # ``category_mask`` is an ``mp.Image`` wrapping a uint8 buffer where
    # 0 = background and 1 = foreground for the selfie segmenter.
    raw = category_mask.numpy_view()
    # Foreground pixels -> 255, background -> 0. Copy because
    # ``numpy_view`` aliases memory owned by the MediaPipe result.
    mask = np.where(raw > 0, 255, 0).astype(np.uint8)

    if feather_radius > 0:
        k = max(1, int(feather_radius) * 2 + 1)
        mask = cv2.GaussianBlur(mask, (k, k), 0)
    return mask


def _build_dim_lut(background_strength: float) -> np.ndarray:
    """Return a 256-entry uint8 LUT that dims bright pixels toward white.

    The mapping is ``v_out = 255 - (255 - v_in) * background_strength``:

    - ``background_strength == 1.0`` -> identity (no dimming).
    - ``background_strength == 0.0`` -> solid white (full dim).
    - ``background_strength == 0.35`` -> lines at 35% of their original
      darkness, matching the on-device default.
    """
    strength = float(np.clip(background_strength, 0.0, 1.0))
    v = np.arange(256, dtype=np.float32)
    out = 255.0 - (255.0 - v) * strength
    return np.clip(out, 0.0, 255.0).astype(np.uint8)


def composite_two_zone(
    filter_output_gray: np.ndarray,
    mask: np.ndarray,
    background_strength: float = 0.35,
) -> np.ndarray:
    """Composite the filter output using a per-pixel two-zone rule.

    Body pixels (mask == 255) use ``filter_output_gray`` directly.
    Background pixels (mask == 0) use the dimmed LUT. Feathered edge
    pixels are linearly blended between the two.

    :param filter_output_gray: ``(H, W)`` uint8 filter output.
    :param mask: ``(H, W)`` uint8 person mask from :func:`get_mask`.
    :param background_strength: 0..1. Lower = more dimming on the
        background. 0.35 matches the shipped app default.
    :returns: ``(H, W)`` uint8 composited grayscale image.
    """
    if filter_output_gray.ndim != 2:
        raise ValueError(
            f"filter_output_gray must be 2D grayscale, "
            f"got shape {filter_output_gray.shape!r}."
        )
    if mask.shape != filter_output_gray.shape:
        mask = cv2.resize(
            mask,
            (filter_output_gray.shape[1], filter_output_gray.shape[0]),
            interpolation=cv2.INTER_LINEAR,
        )

    lut = _build_dim_lut(background_strength)
    dimmed = cv2.LUT(filter_output_gray, lut)

    # Alpha blend: body_alpha = mask/255, out = body_alpha*body + (1-body_alpha)*dim
    alpha = mask.astype(np.float32) / 255.0
    out = (
        alpha * filter_output_gray.astype(np.float32)
        + (1.0 - alpha) * dimmed.astype(np.float32)
    )
    return np.clip(out, 0.0, 255.0).astype(np.uint8)
