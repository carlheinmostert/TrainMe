"""Current-production pencil-sketch filter.

This matches ``filter.py`` at the repo root step-for-step (invert ->
box-blur -> divide -> adaptive threshold -> min-combine -> contrast
stretch) and exposes the three knobs Carl tunes from
``app/lib/config.dart``:

- ``blur_kernel`` — box-blur kernel size (odd, 3..51).
- ``threshold_block`` — adaptive-threshold block size (odd, 3..51).
- ``contrast_low`` — lower bound of the contrast stretch (0..128).

The reference pipeline also exists in two production sources of truth:

- ``app/lib/services/conversion_service.dart`` (photo path + Dart video
  fallback),
- ``app/ios/Runner/VideoConverterChannel.swift`` (native iOS video
  pipeline using vImage box convolution).

We mirror the iOS native path (box blur) because that is what ships to
most video frames in practice.
"""

from __future__ import annotations

from typing import Any

import cv2
import numpy as np

from .base import BaseFilter, ParamSpec


def _force_odd(value: int) -> int:
    value = max(1, int(value))
    return value if value % 2 == 1 else value + 1


class PencilSketchFilter(BaseFilter):
    """Production pencil-sketch filter (invert + blur + divide + threshold)."""

    name = "Pencil Sketch (current production)"
    description = (
        "Classic pencil-sketch pipeline shipping in the iOS app. "
        "Values map directly to AppConfig.blurKernel / thresholdBlock / "
        "contrastLow in app/lib/config.dart."
    )

    params_schema: dict[str, ParamSpec] = {
        "blur_kernel": ParamSpec(
            min=3,
            max=51,
            default=31,
            step=2,
            kind="int",
            odd_only=True,
            description=(
                "Box-blur kernel for the inverted grayscale pass. "
                "Larger = softer, wider lines. Must be odd."
            ),
        ),
        "threshold_block": ParamSpec(
            min=3,
            max=51,
            default=9,
            step=2,
            kind="int",
            odd_only=True,
            description=(
                "Adaptive-threshold block size. Larger = more "
                "neighbourhood context per pixel. Must be odd."
            ),
        ),
        "contrast_low": ParamSpec(
            min=0,
            max=128,
            default=80,
            step=1,
            kind="int",
            description=(
                "Lower bound of the final contrast stretch. "
                "Higher = punchier, more white."
            ),
        ),
    }

    # ---- pipeline steps ------------------------------------------------

    @staticmethod
    def _invert(gray: np.ndarray) -> np.ndarray:
        return cv2.subtract(np.full_like(gray, 255), gray)

    @staticmethod
    def _box_blur(inv: np.ndarray, kernel: int) -> np.ndarray:
        k = _force_odd(kernel)
        return cv2.boxFilter(inv, ddepth=-1, ksize=(k, k))

    @staticmethod
    def _divide_sketch(gray: np.ndarray, blurred_inv: np.ndarray) -> np.ndarray:
        divisor = (
            cv2.subtract(np.full_like(blurred_inv, 255), blurred_inv).astype(np.int32)
            + 1
        )
        sketch = (gray.astype(np.int32) * 256) // divisor
        return np.clip(sketch, 0, 255).astype(np.uint8)

    @staticmethod
    def _adaptive_threshold(gray: np.ndarray, block_size: int) -> np.ndarray:
        block = _force_odd(block_size)
        return cv2.adaptiveThreshold(
            gray,
            255,
            cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY,
            block,
            2,
        )

    @staticmethod
    def _combine_min(sketch: np.ndarray, threshold: np.ndarray) -> np.ndarray:
        return cv2.min(sketch, threshold)

    @staticmethod
    def _contrast_boost(img: np.ndarray, contrast_low: int) -> np.ndarray:
        low = max(0, min(254, int(contrast_low)))
        scale = 255.0 / max(1, 255 - low)
        beta = -low * scale
        out = img.astype(np.float32) * scale + beta
        return np.clip(out, 0, 255).astype(np.uint8)

    # ---- BaseFilter API ------------------------------------------------

    def apply(self, gray_frame: np.ndarray, params: dict[str, Any]) -> np.ndarray:
        if gray_frame.ndim != 2:
            raise ValueError(
                f"PencilSketchFilter expects a 2D grayscale frame, "
                f"got shape {gray_frame.shape!r}."
            )
        blur_kernel = int(params.get("blur_kernel", 31))
        threshold_block = int(params.get("threshold_block", 9))
        contrast_low = int(params.get("contrast_low", 80))

        inv = self._invert(gray_frame)
        blurred_inv = self._box_blur(inv, blur_kernel)
        sketch = self._divide_sketch(gray_frame, blurred_inv)
        thresholded = self._adaptive_threshold(gray_frame, threshold_block)
        combined = self._combine_min(sketch, thresholded)
        boosted = self._contrast_boost(combined, contrast_low)
        return boosted
