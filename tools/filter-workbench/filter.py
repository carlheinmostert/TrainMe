"""Reference implementation of the homefit.studio line-drawing filter.

Keep this in sync with the two production sources of truth:

- `app/lib/services/conversion_service.dart`
    (the `_frameToLineDrawing` / `_frameToLineDrawingSync` pipeline used
    for photos and the Dart fallback video path)
- `app/ios/Runner/VideoConverterChannel.swift`
    (the native iOS video pipeline using vImage box convolution)

The Python port is intentionally small and pure: each pipeline step is
its own function so it is easy to eyeball and extend with a future
"step-by-step" visualisation mode.

Production deliberately uses a box blur on iOS (vImage) and a Gaussian
blur in the Dart fallback. For the workbench we mirror the iOS native
path (box blur) because that is what ships to most frames in practice.
Output is visually close to production but not pixel-identical — this
tool exists for tuning intuition, not pixel verification.
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class Params:
    """Filter parameters. Mirrors the fields on `AppConfig` in config.dart."""

    blur_kernel: int
    threshold_block: int
    contrast_low: int

    def normalised(self) -> "Params":
        """Return a copy with kernel sizes forced odd and >= 1."""
        return Params(
            blur_kernel=_force_odd(self.blur_kernel),
            threshold_block=_force_odd(self.threshold_block),
            contrast_low=max(0, min(254, int(self.contrast_low))),
        )


def _force_odd(value: int) -> int:
    value = max(1, int(value))
    return value if value % 2 == 1 else value + 1


def to_grayscale(bgr: np.ndarray) -> np.ndarray:
    """Step 1: BGR -> grayscale (uint8)."""
    if bgr.ndim == 2:
        return bgr
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)


def invert(gray: np.ndarray) -> np.ndarray:
    """Step 2a: 255 - gray."""
    return cv2.subtract(np.full_like(gray, 255), gray)


def box_blur(inv: np.ndarray, kernel: int) -> np.ndarray:
    """Step 2b: box blur of the inverted grayscale image."""
    k = _force_odd(kernel)
    return cv2.boxFilter(inv, ddepth=-1, ksize=(k, k))


def divide_sketch(gray: np.ndarray, blurred_inv: np.ndarray) -> np.ndarray:
    """Step 2c: sketch = (gray * 256) / (255 - blurred_inv + 1), clipped to 0..255.

    Mirrors the divide step in the Dart and Swift pipelines, which both
    use the classic "pencil sketch via divide" trick.
    """
    # Divisor is `255 - blurred_inv`, guarded against zero with `+ 1`.
    divisor = cv2.subtract(np.full_like(blurred_inv, 255), blurred_inv).astype(np.int32) + 1
    sketch = (gray.astype(np.int32) * 256) // divisor
    return np.clip(sketch, 0, 255).astype(np.uint8)


def adaptive_threshold(gray: np.ndarray, block_size: int) -> np.ndarray:
    """Step 3: adaptive Gaussian threshold. Block size forced odd, C fixed at 2."""
    block = _force_odd(block_size)
    return cv2.adaptiveThreshold(
        gray,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY,
        block,
        2,
    )


def combine_min(sketch: np.ndarray, threshold: np.ndarray) -> np.ndarray:
    """Step 4: pixel-wise min (keeps the darker, more line-like pixel)."""
    return cv2.min(sketch, threshold)


def contrast_boost(img: np.ndarray, contrast_low: int) -> np.ndarray:
    """Step 5: linear stretch of [contrast_low, 255] -> [0, 255], clipped.

    output = clip((input - contrast_low) * 255 / (255 - contrast_low), 0, 255)
    """
    low = max(0, min(254, int(contrast_low)))
    scale = 255.0 / max(1, 255 - low)
    beta = -low * scale
    out = img.astype(np.float32) * scale + beta
    return np.clip(out, 0, 255).astype(np.uint8)


def apply_filter(bgr: np.ndarray, params: Params) -> np.ndarray:
    """Run the full line-drawing pipeline on a BGR image.

    Returns a BGR image so the caller can drop it straight into a grid
    alongside the unmodified originals.
    """
    p = params.normalised()
    gray = to_grayscale(bgr)
    inv = invert(gray)
    blurred_inv = box_blur(inv, p.blur_kernel)
    sketch = divide_sketch(gray, blurred_inv)
    thresholded = adaptive_threshold(gray, p.threshold_block)
    combined = combine_min(sketch, thresholded)
    boosted = contrast_boost(combined, p.contrast_low)
    return cv2.cvtColor(boosted, cv2.COLOR_GRAY2BGR)
