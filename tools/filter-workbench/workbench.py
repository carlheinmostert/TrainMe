"""CLI for comparing line-drawing filter presets on a folder of samples.

Typical use:

    python workbench.py \\
        --samples samples/ \\
        --presets presets.yaml \\
        --output out/grid.jpg

Produces a grid image: one row per sample, one column per preset. The
first column is always the untreated original for reference. Each cell
is labelled with the preset name. Cells are capped at 400x400 pixels so
a handful of samples fits on a laptop screen.

Once a preset looks right, paste its values into `app/lib/config.dart`
(`AppConfig.blurKernel`, `AppConfig.thresholdBlock`, `AppConfig.contrastLow`).
"""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import yaml

from filter import Params, apply_filter


SUPPORTED_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
MAX_CELL_SIZE = 400
LABEL_HEIGHT = 28
ORIGINAL_LABEL = "original"


@dataclass(frozen=True)
class Preset:
    name: str
    params: Params


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Line-drawing filter tuning workbench.",
    )
    parser.add_argument(
        "--samples",
        type=Path,
        required=True,
        help="Folder containing sample images (JPG/PNG/etc).",
    )
    parser.add_argument(
        "--presets",
        type=Path,
        required=True,
        help="YAML file with a list of named parameter sets.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Output grid image path (extension decides encoding).",
    )
    parser.add_argument(
        "--columns",
        type=int,
        default=None,
        help="Maximum number of preset columns to include (default: all).",
    )
    return parser.parse_args(argv)


def load_presets(path: Path) -> list[Preset]:
    with path.open("r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh)
    if not isinstance(raw, list):
        raise ValueError(f"{path}: expected a YAML list of preset dicts.")
    presets: list[Preset] = []
    for idx, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ValueError(f"{path}[{idx}]: expected a dict, got {type(item).__name__}.")
        try:
            presets.append(
                Preset(
                    name=str(item["name"]),
                    params=Params(
                        blur_kernel=int(item["blur_kernel"]),
                        threshold_block=int(item["threshold_block"]),
                        contrast_low=int(item["contrast_low"]),
                    ),
                )
            )
        except KeyError as exc:
            raise ValueError(f"{path}[{idx}]: missing field {exc!s}.") from exc
    if not presets:
        raise ValueError(f"{path}: no presets defined.")
    return presets


def list_samples(folder: Path) -> list[Path]:
    if not folder.is_dir():
        raise FileNotFoundError(f"Samples folder not found: {folder}")
    samples = sorted(
        p for p in folder.iterdir()
        if p.is_file() and p.suffix.lower() in SUPPORTED_EXTS
    )
    if not samples:
        raise FileNotFoundError(
            f"No images with extensions {sorted(SUPPORTED_EXTS)} found in {folder}."
        )
    return samples


def fit_cell(img: np.ndarray, max_size: int = MAX_CELL_SIZE) -> np.ndarray:
    """Downscale an image to fit inside max_size x max_size, preserving aspect."""
    h, w = img.shape[:2]
    longest = max(h, w)
    if longest <= max_size:
        return img.copy()
    scale = max_size / longest
    new_w = max(1, int(round(w * scale)))
    new_h = max(1, int(round(h * scale)))
    return cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA)


def canvas_cell(img: np.ndarray, cell_w: int, cell_h: int) -> np.ndarray:
    """Centre `img` on a black canvas of exactly cell_w x cell_h."""
    canvas = np.zeros((cell_h, cell_w, 3), dtype=np.uint8)
    h, w = img.shape[:2]
    y = (cell_h - h) // 2
    x = (cell_w - w) // 2
    canvas[y:y + h, x:x + w] = img
    return canvas


def annotate(cell: np.ndarray, label: str) -> np.ndarray:
    """Draw a readable label strip across the top of the cell."""
    out = cell.copy()
    h, w = out.shape[:2]
    cv2.rectangle(out, (0, 0), (w, LABEL_HEIGHT), (0, 0, 0), thickness=-1)
    cv2.putText(
        out,
        label,
        (8, LABEL_HEIGHT - 9),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.5,
        (255, 255, 255),
        1,
        cv2.LINE_AA,
    )
    return out


def build_row(
    sample: np.ndarray,
    preset_outputs: list[tuple[str, np.ndarray]],
    cell_w: int,
    cell_h: int,
) -> np.ndarray:
    cells = [annotate(canvas_cell(fit_cell(sample), cell_w, cell_h), ORIGINAL_LABEL)]
    for name, converted in preset_outputs:
        cells.append(annotate(canvas_cell(fit_cell(converted), cell_w, cell_h), name))
    return cv2.hconcat(cells)


def build_grid(
    samples: list[tuple[Path, np.ndarray]],
    presets: list[Preset],
) -> tuple[np.ndarray, dict[str, float]]:
    """Build the full grid image and return it with per-preset timing totals."""
    # Figure out cell size from the largest sample so the grid is uniform.
    fitted = [fit_cell(img) for _, img in samples]
    cell_w = max(img.shape[1] for img in fitted)
    cell_h = max(img.shape[0] for img in fitted)

    timings: dict[str, float] = {p.name: 0.0 for p in presets}
    rows: list[np.ndarray] = []
    for (path, original), small in zip(samples, fitted):
        preset_outputs: list[tuple[str, np.ndarray]] = []
        for preset in presets:
            start = time.perf_counter()
            converted = apply_filter(original, preset.params)
            timings[preset.name] += time.perf_counter() - start
            preset_outputs.append((preset.name, converted))
        rows.append(build_row(original, preset_outputs, cell_w, cell_h))
        print(f"  processed {path.name}")
    grid = cv2.vconcat(rows)
    return grid, timings


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    presets = load_presets(args.presets)
    if args.columns is not None and args.columns > 0:
        presets = presets[: args.columns]

    sample_paths = list_samples(args.samples)
    samples: list[tuple[Path, np.ndarray]] = []
    for path in sample_paths:
        img = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if img is None:
            print(f"  skipping (unreadable): {path}", file=sys.stderr)
            continue
        samples.append((path, img))
    if not samples:
        print("No readable samples. Drop images into the samples folder.", file=sys.stderr)
        return 1

    print(f"Samples: {len(samples)}  Presets: {len(presets)}")
    grid, timings = build_grid(samples, presets)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    ok = cv2.imwrite(str(args.output), grid)
    if not ok:
        print(f"Failed to write grid to {args.output}", file=sys.stderr)
        return 1

    h, w = grid.shape[:2]
    print(f"\nWrote {args.output}  ({w}x{h} px)")
    print("\nTimings per preset (total across all samples):")
    for name, seconds in timings.items():
        print(f"  {name:<24} {seconds * 1000:8.1f} ms")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
