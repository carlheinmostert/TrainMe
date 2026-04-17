# filter-workbench

An interactive workbench for tuning the homefit.studio on-device
line-drawing filter. Ships two surfaces:

- **`workbench_ui.py`** — a Streamlit app with live-slider tweaking
  against real published exercise clips, MediaPipe person segmentation
  for the body-crisp / background-dimmed two-zone render, and a
  pluggable filter architecture.
- **`workbench.py`** — the original CLI (batch grid across a folder of
  samples). Still works; kept for parity with existing notes.

## Install

```bash
cd tools/filter-workbench
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Python 3.10 or newer.

MediaPipe is a heavy dependency (downloads ~150 MB of wheels,
depending on platform). Expect the first `pip install` to take a
minute or two.

The first run of the Streamlit app with segmentation enabled also
auto-downloads the MediaPipe selfie-segmenter model (~5-10 MB
`.tflite` file) into `cache/selfie_segmenter.tflite`. Subsequent
runs use the cached copy.

## Run (Streamlit)

From the repo root:

```bash
cd tools/filter-workbench
streamlit run workbench_ui.py
```

Streamlit opens at [http://localhost:8501](http://localhost:8501).

Workflow:

1. **Pick a published plan** from the sidebar dropdown. Plans are
   pulled live from Supabase (`GET /rest/v1/plans`) filtered to
   `sent_at IS NOT NULL` and sorted newest-first.
2. **Pick a video exercise** from that plan. Photos and rest periods
   are filtered out — the workbench earns its keep on video.
3. **Scrub the frame slider** (30 evenly-spaced frames across the
   clip). First load downloads the video and extracts all 30 frames
   into `cache/`; subsequent tweaks hit the cache.
4. **Pick a filter algorithm** from the top dropdown.
5. **Tweak the auto-generated sliders**. The page re-runs live — no
   apply button.
6. **Toggle segmentation** on/off, and drag **Background dim strength**
   until the non-body edges feel right (default `0.35` matches
   on-device).
7. **Copy the parameters** from the Dart snippet at the bottom into
   `app/lib/config.dart`, rebuild, install, done.

## Environment variables

Both default to the same publishable credentials used by
`app/lib/config.dart`, so it works out of the box. Override if you
want to point at a different Supabase project:

| Variable              | Default                                           |
| --------------------- | ------------------------------------------------- |
| `SUPABASE_URL`        | `https://yrwcofhovrcydootivjx.supabase.co`        |
| `SUPABASE_ANON_KEY`   | `sb_publishable_...` (matches `config.dart`)      |

## Adding a new filter

The Streamlit app auto-discovers every filter registered in
`filters/__init__.py`. To add one:

1. Create a new module in `filters/` (e.g. `filters/edge_cartoon.py`).
2. Define a class that subclasses `filters.base.BaseFilter`. Populate
   `name`, optionally `description`, and `params_schema` with one
   `ParamSpec` per tunable knob.
3. Implement `apply(gray_frame, params) -> np.ndarray`. Input and
   output are both single-channel uint8 grayscale. Do NOT do
   segmentation or compositing in `apply` — the UI layer handles
   that uniformly across all filters.
4. Import your class in `filters/__init__.py` and append an instance
   to the `FILTERS` list.

Reference: `filters/pencil_sketch.py` — current production pipeline.

`ParamSpec` supports three widget kinds:

| `kind`   | Widget                   |
| -------- | ------------------------ |
| `"int"`  | `st.slider` (int step)   |
| `"float"`| `st.slider` (float step) |
| `"bool"` | `st.checkbox`            |

Set `odd_only=True` on integer specs for kernel-size knobs — the UI
snaps values up to the next odd integer.

## Segmentation caveat

The Python MediaPipe SelfieSegmentation model is NOT pixel-identical
to the iOS Vision framework used in production (different
architectures, different training data). Expect the same general
behaviour — body vs background — but with slightly different edge
fidelity and occasional dropouts on unusual poses.

Practical consequence: tune `background_strength` **together with**
the filter params, not independently. A value that looks great in
the workbench may need a small nudge (± 0.05-0.10) on-device.

## CLI (original workbench.py)

Unchanged. Useful for generating a printable grid of presets from a
folder of samples:

```bash
python workbench.py \
  --samples samples/ \
  --presets presets.yaml \
  --output out/grid.jpg
```

See `presets.yaml` for the preset format.

## Files

- `workbench_ui.py` — Streamlit app entry point.
- `filters/base.py` — `BaseFilter` ABC + `ParamSpec` dataclass.
- `filters/pencil_sketch.py` — current production pipeline as the
  reference filter.
- `filters/__init__.py` — filter registry (`FILTERS`).
- `segmentation.py` — MediaPipe SelfieSegmentation wrapper and
  `composite_two_zone` compositor.
- `supabase_client.py` — `fetch_published_plans` + `download_video`.
- `frame_extractor.py` — pulls N evenly-spaced frames from a video.
- `cache/` — gitignored; downloaded videos and extracted frames.
- `filter.py` — legacy reference filter (used only by the CLI).
- `workbench.py` — legacy CLI batch-grid tool.
- `presets.yaml` — preset list for the CLI.
- `samples/` — gitignored, for CLI manual testing.
- `out/` — gitignored, CLI grid outputs land here.

## Once you have a winner

Open `app/lib/config.dart` and paste the three line-drawing constants
from the Dart snippet at the bottom of the Streamlit page:

```dart
static const int blurKernel = 31;
static const int thresholdBlock = 9;
static const int contrastLow = 80;
```

Then rebuild and install the app:

```bash
cd app && flutter build ios --debug --simulator
xcrun simctl install <device-id> build/ios/iphonesimulator/Runner.app
```
