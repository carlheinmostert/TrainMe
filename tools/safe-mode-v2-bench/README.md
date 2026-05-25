# safe-mode-v2-bench

A standalone macOS command-line tool that mirrors the Safe Mode v2
pipelines from `app/ios/Runner/VideoConverterChannel.swift` byte-for-
byte. Two modes:

- **Photo** (`--photo <path.jpg>`) — mirrors `applySafeModeV2ToPhoto`.
  Originally built to debug the all-frame-blur bug when the cosine-
  similarity test silently rejected every face. Prints every internal
  decision (per-face cosSim, subject choice, mask coverage, blur
  fraction) and writes the safe-variant JPG.
- **Video** (`--video <path.mp4>`) — mirrors `SafeModeV2VideoProcessor`.
  Runs the hybrid state machine (first-frame identify + Vision tracker
  + sparse re-confirm via face-rec every 2s) frame-for-frame and emits
  per-clip stats (subject identification rate, re-confirm / re-seed /
  tracker-loss event counts, avg cosSim, miss rate, wall clock, realtime
  ratio). Use `generate_video_report.py` for the side-by-side HTML
  report Carl reads before approving device QA.

## Table of Contents

- [What it does](#what-it-does)
- [Build](#build)
- [Run a single photo](#run-a-single-photo)
- [Sweep thresholds](#sweep-thresholds)
- [Fetch an embedding from staging](#fetch-an-embedding-from-staging)
- [Diagnostic output format](#diagnostic-output-format)
- [Known divergences from iOS](#known-divergences-from-ios)
- [Files](#files)

## What it does

Given a JPG + a raw 2048-byte face embedding + a cosine-similarity
threshold, this tool:

1. Pre-renders the JPG upright (honoring EXIF orientation) at up to
   1920px.
2. Runs `VNDetectFaceRectanglesRequest`.
3. For every detected face: crops with 20% pad, embeds via
   MobileFaceNet (the same `.mlmodel` shipped to the iOS app),
   computes cosine similarity vs the supplied subject embedding.
4. Picks the highest-cosSim face as the candidate subject; flips
   `subjectIdentified=true` iff bestSim >= threshold.
5. Runs `VNGeneratePersonSegmentationRequest` (`.accurate`).
6. Builds the keep-source mask via flood-fill + head-expansion,
   identical to iOS (`applySafeModeV2ToPhoto`).
7. Composites source vs CIGaussianBlur via CIBlendWithMask.
8. Writes the safe variant as a 0.9-quality JPG.

The diagnostic block printed to stdout is the whole point. iOS NSLog
on this wave is invisible via `idevicesyslog`, so we needed a
developer-machine surface that prints to stdout where we can read it.

## Build

```bash
cd tools/safe-mode-v2-bench
swift build
```

First build takes a minute (SwiftPM compiles `MobileFaceNet.mlmodel`
to `MobileFaceNet.mlmodelc` via Apple's `coremlcompiler` toolchain).
Subsequent builds are near-instant.

Requirements: macOS 15+, Swift 6.0+ (ships with Xcode 16).

## Run a single photo

```bash
swift run SafeModeBench \
  --photo samples/selfie_01.jpg \
  --embedding samples/embedding.bin \
  --threshold 0.5 \
  --output /tmp/selfie_01_safe.jpg
```

Optional knobs:
- `--area-clamp 0.35` — max fraction of frame each head-expansion may
  cover (default 0.35 matches the iOS clamp added in PR #455).
- `--head-expand-w 2.0` / `--head-expand-h 1.5` — face bbox
  multipliers for the rectangular head-region paint.
- `--max-work-dim 1920` — max working pixel dimension (default 1920
  matches iOS).

## Sweep thresholds

```bash
./sweep.sh samples/selfie_01.jpg
# or:
./sweep.sh samples/selfie_01.jpg samples/embedding.bin
```

This iterates thresholds [0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70],
writes seven safe variants to `/tmp/safe_mode_bench/<basename>/`,
produces a TSV summary + an HTML grid, then opens the HTML in your
default browser. Eyeball which threshold flips a given subject from
"every face blurred" to "subject sharp."

## Fetch an embedding from staging

```bash
# 1. Get the staging Postgres connection string from Supabase dashboard
#    (project vadjvkmldtoeyspyoqbx → Project Settings → Database →
#    Connection string → Transaction pooler).
export STAGING_DB_URL='postgresql://postgres.vadjvkmldtoeyspyoqbx:PWD@aws-…:6543/postgres'

# 2. Pull the embedding for a client by UUID:
./fetch_embedding.sh 53004519-9b14-45d2-87c0-ac376b19b0b7 > samples/embedding.bin

# 3. Sanity-check:
ls -la samples/embedding.bin   # should be exactly 2048 bytes
```

The script hard-refuses to run against the prod project ref
(`yrwcofhovrcydootivjx`) so a wrong env var can't pull production data.

## Diagnostic output format

For each invocation:

```
SafeModeBench v1
photo:        samples/selfie_01.jpg
embedding:    samples/embedding.bin (2048 bytes, L2 norm=1.0000)
threshold:    0.500
…
frame:        1920x1440 (2764800 px)
faces:        2
face[0]: bbox=(620,340,540x680) pixels  cosSim=0.4382  rank=1
face[1]: bbox=(140,420,210x260) pixels  cosSim=0.0871  rank=2
DECISION: subjectIdentified=false  subjectIdx=nil  bestSim=0.4382  threshold=0.5000
SEGMENTATION: maskPositivePixels=384012 / totalPixels=2764800 (13.9%)
FLOOD-FILL: (skipped — no subject identified)
COMPOSITE: blurPixels=228040 (8.2% of frame painted to blur target)
OUTPUT: written to /tmp/selfie_01_safe.jpg
elapsed:      842.1 ms
```

The lines you'll read most:

- **`face[i] cosSim=…`** — actual similarity of each face vs the
  subject embedding. If your own selfie's face has cosSim < 0.3
  against your own embedding, either the embedding is corrupted or
  the face crop is bad.
- **`DECISION: subjectIdentified=…`** — flipped to true only if any
  face's cosSim >= threshold.
- **`SEGMENTATION: …%`** — fraction of frame Vision marked as
  person-positive. Low values (< 5%) suggest Vision didn't pick up
  the silhouette.
- **`COMPOSITE: blurPixels=… (X% of frame)`** — bottom line. > 50%
  means almost everything got blurred (the bug we're hunting).

The 2048-byte sanity-check line at the top is gold: if the embedding
file's L2 norm reads as `0.0000` or `100.0000` you know the bytes
got corrupted in transit (hex-decode failure, endianness flip, etc).
A valid L2 norm reads `1.0000` (model output is L2-normalized).

## Known divergences from iOS

The pipeline mirrors iOS step-for-step. The visible differences are
UIKit-only and don't affect the math:

| iOS                             | macOS bench                              |
|---------------------------------|------------------------------------------|
| `UIImage(contentsOfFile:)`      | `CGImageSourceCreateWithURL`             |
| `UIImage.imageOrientation`      | `kCGImagePropertyOrientation` from EXIF  |
| `UIGraphicsImageRenderer`       | CGContext + manual EXIF affine transform |
| `UIImage.jpegData(quality:)`    | `CGImageDestination` (UTType.jpeg)       |
| `Bundle.main` for the .mlmodel  | `Bundle.module` (SwiftPM-per-target)     |

CoreML + Vision + CoreImage + Accelerate are platform-independent and
behave identically across iOS 15+ / macOS 12+. The MobileFaceNet model
file is byte-identical to the one shipped to the iOS app.

The one subtle thing: Vision's `VNGeneratePersonSegmentationRequest`
quality `.accurate` runs on the Neural Engine on Apple Silicon
(iOS + macOS). On Intel Macs without a Neural Engine, Vision falls
back to GPU and you might see slightly different mask edges — Apple
documents this but we haven't observed it materially affecting the
flood-fill or composite outputs.

## Run a video bench (with HTML report)

The video bench is wired to the side-by-side report Carl reads before
approving any Safe Mode device QA (per `feedback_safe_mode_bench_report`).

```bash
# 1. Drop 3-5 short test clips (5-15s each) into samples/
#    covering the scenarios from docs/specs/2026-05-25-safe-mode-v2-video.md §7:
#      solo subject / bystander pass / crossover / first-frame fail / occlusion
ls samples/
# selfie_solo.mp4
# bystander_pass.mp4
# crossover.mp4
# back_then_front.mp4
# occlusion.mp4

# 2. Pull the practitioner's embedding (same as photo bench, --help fetch_embedding.sh)
./fetch_embedding.sh <client-uuid> > samples/embedding.bin

# 3. Render the report
python3 generate_video_report.py \
  --bench . \
  --embedding samples/embedding.bin \
  --output "/Users/chm/Desktop/Safe Mode Bench Report.html"

# 4. Carl opens the HTML, eyeballs each pair, signs off on device QA.
open "/Users/chm/Desktop/Safe Mode Bench Report.html"
```

The report writes safe variants to `/tmp/safe_mode_v2_video_bench/`
by default. Re-running with `--skip-bench` skips the (slow) bench run
and re-renders the HTML against the cached outputs.

Single-clip mode for ad-hoc tuning (no HTML report, just stdout stats):

```bash
swift run SafeModeBench \
  --video samples/selfie_solo.mp4 \
  --embedding samples/embedding.bin \
  --threshold 0.55 \
  --reconfirm-interval-sec 2.0 \
  --output /tmp/selfie_solo_safe.mp4
```

## Files

```
Package.swift                                       # SwiftPM manifest (Swift 6 / macOS 15)
Sources/SafeModeBench/main.swift                    # CLI entry + arg parser (photo + video)
Sources/SafeModeBench/SafeModeV2Pipeline.swift      # Photo pipeline + EXIF + JPG encode
Sources/SafeModeBench/SafeModeV2VideoPipeline.swift # Video pipeline + state machine
Sources/SafeModeBench/MobileFaceNetEmbedder.swift   # macOS-compatible embedder
Sources/SafeModeBench/PersonSegmenter.swift         # Vision segmenter + hand-pose dilator
Sources/SafeModeBench/MobileFaceNet.mlmodel         # Copy of the iOS .mlmodel (4.7MB)
samples/                                             # gitignored — drop test inputs here
samples/README.md                                   # how to populate samples/
sweep.sh                                             # photo threshold sweep + HTML grid
generate_video_report.py                            # video bench HTML report generator
fetch_embedding.sh                                   # pull face_embedding from staging DB
README.md                                            # you are here
```

## Out of scope

- Any iOS app changes — this is purely a developer-side debug tool.
- Tuning the live pipeline behavior (that's a separate PR on the
  iOS code once the bench identifies what to tune).
- Web portal / Flutter — unrelated.
- CI — manual `swift build` only. No GitHub Actions job.
