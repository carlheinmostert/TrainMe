#!/usr/bin/env python3
"""Generate an HTML iteration report for the Safe Mode v2 photo fix
autonomous iteration loop.

Usage:
  generate_iter_report.py \
    --attempt N \
    --hypothesis "what we tried this attempt" \
    --source /tmp/tp2-sample.jpg \
    --output /tmp/safe-mode-bench-attempt-N.jpg \
    --assessor-output /tmp/assessor-N.txt \
    --html /tmp/safe-mode-bench-iter-N.html
"""
from __future__ import annotations

import argparse
import base64
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from scipy import ndimage


def _open_upright(path: Path) -> Image.Image:
    """Open an image and honor EXIF orientation."""
    img = Image.open(path)
    return ImageOps.exif_transpose(img)

GRID_N = 16


def b64_image(path: Path, max_dim: int = 600) -> str:
    img = _open_upright(path).convert("RGB")
    img.thumbnail((max_dim, max_dim))
    import io

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def heatmap_overlay(source_path: Path, output_path: Path) -> str:
    """Render a heatmap overlay where each grid cell is colored by
    output_var / source_var ratio. Green=sharp (high ratio), red=blurred
    (low ratio). Overlay on the OUTPUT image (downsized)."""
    src = np.asarray(_open_upright(source_path).convert("L"), dtype=np.uint8)
    out = np.asarray(_open_upright(output_path).convert("L"), dtype=np.uint8)
    if src.shape != out.shape:
        out_img = _open_upright(output_path).convert("RGB").resize(
            (src.shape[1], src.shape[0]),
            Image.BILINEAR,
        )
        out = np.asarray(out_img.convert("L"), dtype=np.uint8)
    src_lap = ndimage.laplace(src.astype(np.float64))
    out_lap = ndimage.laplace(out.astype(np.float64))
    h, w = src_lap.shape
    cell_h = h // GRID_N
    cell_w = w // GRID_N
    src_vars = np.zeros((GRID_N, GRID_N), dtype=np.float64)
    out_vars = np.zeros((GRID_N, GRID_N), dtype=np.float64)
    for r in range(GRID_N):
        for c in range(GRID_N):
            y0 = r * cell_h
            x0 = c * cell_w
            y1 = (r + 1) * cell_h if r < GRID_N - 1 else h
            x1 = (c + 1) * cell_w if c < GRID_N - 1 else w
            src_vars[r, c] = src_lap[y0:y1, x0:x1].var()
            out_vars[r, c] = out_lap[y0:y1, x0:x1].var()
    ratios = np.where(src_vars > 1e-6, out_vars / np.maximum(src_vars, 1e-6), 1.0)

    # Build overlay image. Use output image as base.
    base = _open_upright(output_path).convert("RGB").resize((w, h), Image.BILINEAR)
    base_arr = np.asarray(base, dtype=np.uint8).copy()
    # Per-cell tint: red where ratio < 0.5 (blurred), green where >= 0.85,
    # yellow-ish in-between.
    for r in range(GRID_N):
        for c in range(GRID_N):
            y0 = r * cell_h
            x0 = c * cell_w
            y1 = (r + 1) * cell_h if r < GRID_N - 1 else h
            x1 = (c + 1) * cell_w if c < GRID_N - 1 else w
            ratio = ratios[r, c]
            if ratio < 0.5:
                # red tint
                tint = np.array([255, 50, 50], dtype=np.float64)
                alpha = 0.55
            elif ratio < 0.85:
                tint = np.array([255, 220, 50], dtype=np.float64)
                alpha = 0.40
            else:
                tint = np.array([60, 220, 80], dtype=np.float64)
                alpha = 0.25
            patch = base_arr[y0:y1, x0:x1].astype(np.float64)
            blended = patch * (1 - alpha) + tint * alpha
            base_arr[y0:y1, x0:x1] = blended.clip(0, 255).astype(np.uint8)
    overlay_img = Image.fromarray(base_arr)
    overlay_img.thumbnail((600, 600))
    import io

    buf = io.BytesIO()
    overlay_img.save(buf, format="JPEG", quality=85)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


HTML_TMPL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Safe Mode v2 Photo Fix — Iteration {attempt}</title>
<style>
  body {{ font-family: -apple-system, sans-serif; background: #0F1117; color: #fff; margin: 0; padding: 24px; }}
  h1 {{ font-weight: 700; }}
  .hyp {{ background: #1A1F2A; padding: 16px; border-left: 4px solid #FF6B35; margin: 16px 0; white-space: pre-wrap; }}
  .row {{ display: flex; gap: 16px; flex-wrap: wrap; margin: 24px 0; }}
  .col {{ flex: 1 1 360px; min-width: 280px; }}
  .col h3 {{ margin: 0 0 8px 0; font-weight: 600; color: #ccc; font-size: 14px; }}
  .col img {{ width: 100%; height: auto; border: 1px solid #333; border-radius: 4px; display: block; }}
  pre {{ background: #0a0a0a; padding: 16px; border-radius: 4px; overflow: auto; font-size: 13px; white-space: pre-wrap; }}
  .pass {{ color: #86EFAC; font-weight: 700; }}
  .fail {{ color: #FF6B35; font-weight: 700; }}
  .verdict {{ font-size: 18px; padding: 12px 16px; border-radius: 4px; display: inline-block; }}
  .verdict.pass {{ background: #1A3A24; }}
  .verdict.fail {{ background: #3A1A1A; }}
</style>
</head>
<body>
<h1>Safe Mode v2 — Iteration {attempt}</h1>
<div class="hyp"><strong>Hypothesis tested:</strong>
{hypothesis}</div>
<div class="row">
  <div class="col">
    <h3>Source (/tmp/tp2-sample.jpg)</h3>
    <img src="{src_img}" alt="source">
  </div>
  <div class="col">
    <h3>Output (attempt {attempt})</h3>
    <img src="{out_img}" alt="output">
  </div>
  <div class="col">
    <h3>Heatmap (red = blurred, green = sharp)</h3>
    <img src="{heat_img}" alt="heatmap">
  </div>
</div>
<h2>Assessor output</h2>
<pre>{assessor_output}</pre>
<div class="verdict {verdict_class}">VERDICT: {verdict}</div>
</body>
</html>
"""


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--attempt", required=True, type=int)
    p.add_argument("--hypothesis", required=True)
    p.add_argument("--source", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--assessor-output", required=True, type=Path)
    p.add_argument("--html", required=True, type=Path)
    args = p.parse_args()

    assessor_text = args.assessor_output.read_text() if args.assessor_output.exists() else "(no assessor output)"
    verdict = "FAIL"
    for line in assessor_text.splitlines():
        if line.startswith("=== VERDICT:"):
            if "PASS" in line:
                verdict = "PASS"
            break
    src_img = b64_image(args.source)
    out_img = b64_image(args.output)
    heat = heatmap_overlay(args.source, args.output)

    html = HTML_TMPL.format(
        attempt=args.attempt,
        hypothesis=args.hypothesis,
        src_img=src_img,
        out_img=out_img,
        heat_img=heat,
        assessor_output=assessor_text,
        verdict=verdict,
        verdict_class="pass" if verdict == "PASS" else "fail",
    )
    args.html.write_text(html)
    print("wrote {}".format(args.html))
    return 0


if __name__ == "__main__":
    sys.exit(main())
