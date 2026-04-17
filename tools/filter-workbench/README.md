# filter-workbench

A tiny CLI for tuning the homefit.studio line-drawing filter without
rebuilding and reinstalling the iOS app on every iteration.

## What it does

Takes a folder of reference frames, runs the line-drawing filter against
each one using every preset you list in `presets.yaml`, and writes a
single labelled grid image:

- one **row** per sample image
- one **column** per preset, with the **leftmost column** always showing
  the untreated original for reference
- each cell is annotated with the preset name in a small text strip

Compare looks side-by-side, pick a winner, paste the values into
`app/lib/config.dart`.

## Install

```bash
cd tools/filter-workbench
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Python 3.10 or newer.

## Run

1. Drop a handful of reference frames into `samples/` (JPG, PNG, BMP or
   WebP). The `samples/` directory is gitignored — this is a local
   scratch space.
2. Edit `presets.yaml` to add or tweak the variants you want to compare.
3. Run:

   ```bash
   python workbench.py \
     --samples samples/ \
     --presets presets.yaml \
     --output out/grid.jpg
   ```

Optional flags:

- `--columns N` — only use the first N presets from the YAML file.

The script prints per-preset timing totals at the end so you can spot
presets that are unusually expensive.

## Grid layout

```
+------------+----------------+---------+---------+
| original   | current_prod.  | softer  | harder  |
+------------+----------------+---------+---------+
| sample1.jpg                                     |
+------------+----------------+---------+---------+
| sample2.jpg                                     |
+------------+----------------+---------+---------+
```

Cells are capped at **400x400 px**; a 3-sample x 4-preset grid is roughly
**2000 x 1200 px**, which fits comfortably on a laptop screen.

## Once you have a winner

Open `app/lib/config.dart` and update the three line-drawing constants
on `AppConfig`:

```dart
static const int blurKernel = 31;
static const int thresholdBlock = 9;
static const int contrastLow = 80;
```

Then rebuild and install the app in the usual way:

```bash
cd app && flutter build ios --debug --simulator
xcrun simctl install <device-id> build/ios/iphonesimulator/Runner.app
```

## Important caveat: close, not identical

The production pipeline is a mix of Dart + `opencv_dart` (photo path and
Dart video fallback) and Swift + vImage/Accelerate (native iOS video
path). This Python tool uses `opencv-python`.

Differences you should expect:

- **Box blur vs Gaussian blur.** The native iOS pipeline uses a box blur
  (`vImageBoxConvolve_Planar8`). The Dart fallback uses a Gaussian blur
  of the same radius. This tool matches the native path.
- **Colour space handling, rounding, and JPEG encoding** all vary in
  subtle ways across OpenCV, vImage, and AVAssetWriter.

The workbench is for **tuning intuition and look comparison**, not
pixel-level verification. Expect outputs to be visually very close but
not bit-identical to what the app produces.

## Files

- `filter.py` — reference filter implementation; each pipeline step is a
  small pure function. Docstring points at the two production sources
  of truth to keep in sync with.
- `workbench.py` — CLI entry point, YAML loading, grid building.
- `presets.yaml` — parameter sets to compare.
- `requirements.txt` — pinned Python deps.
- `samples/` — gitignored, drop reference frames here.
- `out/` — gitignored, grid images land here.
