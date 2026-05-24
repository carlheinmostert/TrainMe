#!/usr/bin/env bash
#
# sweep.sh — iterate a fixed set of cosine-sim thresholds against one
# photo + one embedding and produce an HTML grid of the resulting safe
# variants for side-by-side inspection.
#
# Usage:
#   ./sweep.sh <photo.jpg>          (defaults to samples/embedding.bin)
#   ./sweep.sh <photo.jpg> <embedding.bin>
#
# Outputs:
#   /tmp/safe_mode_bench/<photo_basename>/safe_<threshold>.jpg
#   /tmp/safe_mode_bench/<photo_basename>/summary.tsv
#   /tmp/safe_mode_bench/<photo_basename>/index.html  (auto-opens)

set -euo pipefail

cd "$(dirname "$0")"

if [ $# -lt 1 ]; then
  echo "usage: $0 <photo.jpg> [embedding.bin]"
  echo "  photo:     path to selfie or capture JPG"
  echo "  embedding: defaults to samples/embedding.bin"
  exit 1
fi

PHOTO="$1"
EMBED="${2:-samples/embedding.bin}"

if [ ! -f "$PHOTO" ]; then
  echo "error: photo not found: $PHOTO" >&2
  exit 2
fi
if [ ! -f "$EMBED" ]; then
  echo "error: embedding not found: $EMBED" >&2
  echo "       hint: run ./fetch_embedding.sh <client_id> > samples/embedding.bin" >&2
  exit 2
fi

BASE="$(basename "$PHOTO" .jpg)"
OUT_DIR="/tmp/safe_mode_bench/$BASE"
mkdir -p "$OUT_DIR"

THRESHOLDS=(0.10 0.20 0.30 0.40 0.50 0.60 0.70)

# Build once so swift run doesn't rebuild on every iteration.
echo "building SafeModeBench…"
swift build 2>&1 | tail -3

TSV="$OUT_DIR/summary.tsv"
printf "threshold\tbestSim\tsubjectIdentified\tblurFractionPct\tfaceCount\toutputPath\telapsedMs\n" > "$TSV"

for t in "${THRESHOLDS[@]}"; do
  OUT="$OUT_DIR/safe_${t}.jpg"
  LOG="$OUT_DIR/log_${t}.txt"
  echo "--- threshold=$t ---"
  swift run --skip-build SafeModeBench \
    --photo "$PHOTO" \
    --embedding "$EMBED" \
    --threshold "$t" \
    --output "$OUT" 2>&1 | tee "$LOG" | tail -10

  BEST_SIM=$(grep '^DECISION:' "$LOG" | sed -E 's/.*bestSim=([0-9.-]+).*/\1/')
  SUBJECT_ID=$(grep '^DECISION:' "$LOG" | sed -E 's/.*subjectIdentified=([a-z]+).*/\1/')
  BLUR_PCT=$(grep '^COMPOSITE:' "$LOG" | sed -E 's/.*\(([0-9.]+)%.*/\1/')
  FACE_COUNT=$(grep '^faces:' "$LOG" | awk '{print $2}')
  ELAPSED=$(grep '^elapsed:' "$LOG" | sed -E 's/.*: +([0-9.]+) ms.*/\1/')

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$t" "$BEST_SIM" "$SUBJECT_ID" "$BLUR_PCT" "$FACE_COUNT" "$OUT" "$ELAPSED" >> "$TSV"
done

# Build HTML summary grid.
HTML="$OUT_DIR/index.html"
{
  cat <<HTML_HEAD
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>SafeModeBench sweep — $BASE</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
           background: #111; color: #eee; margin: 24px; }
    h1 { font-weight: 600; font-size: 18px; margin-bottom: 12px; }
    .meta { color: #888; font-size: 13px; margin-bottom: 24px; }
    table.summary { border-collapse: collapse; margin-bottom: 24px; }
    table.summary th, table.summary td {
      padding: 6px 12px; border: 1px solid #333; font-size: 13px;
      text-align: left;
    }
    table.summary th { background: #222; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
    .cell { background: #1a1a1a; border: 1px solid #333; border-radius: 6px; overflow: hidden; }
    .cell .label { padding: 10px 12px; font-size: 13px; }
    .cell .label .t { color: #ff6b35; font-weight: 600; }
    .cell .label .sim { color: #86efac; }
    .cell .label .blur { color: #888; }
    .cell img { display: block; width: 100%; height: auto; background: #000; }
    .original { margin-bottom: 24px; }
    .original img { max-width: 480px; border-radius: 6px; }
  </style>
</head>
<body>
  <h1>SafeModeBench sweep — $BASE</h1>
  <div class="meta">
    photo: <code>$PHOTO</code><br>
    embedding: <code>$EMBED</code>
  </div>

  <div class="original">
    <h2 style="font-size:14px;color:#888;">source</h2>
    <img src="file://$(cd "$(dirname "$PHOTO")" && pwd)/$(basename "$PHOTO")">
  </div>

  <h2 style="font-size:14px;color:#888;">summary</h2>
  <table class="summary">
    <thead>
      <tr><th>threshold</th><th>bestSim</th><th>subjectIdentified</th><th>blurFraction</th><th>faces</th><th>elapsed</th></tr>
    </thead>
    <tbody>
HTML_HEAD

  while IFS=$'\t' read -r t bestSim subj blurPct faceCount outPath elapsedMs; do
    if [ "$t" = "threshold" ]; then continue; fi
    echo "      <tr><td>$t</td><td>$bestSim</td><td>$subj</td><td>${blurPct}%</td><td>$faceCount</td><td>${elapsedMs} ms</td></tr>"
  done < "$TSV"

  cat <<HTML_GRID
    </tbody>
  </table>

  <h2 style="font-size:14px;color:#888;">outputs</h2>
  <div class="grid">
HTML_GRID

  while IFS=$'\t' read -r t bestSim subj blurPct faceCount outPath elapsedMs; do
    if [ "$t" = "threshold" ]; then continue; fi
    echo "    <div class='cell'>"
    echo "      <img src='file://$outPath'>"
    echo "      <div class='label'>"
    echo "        threshold <span class='t'>$t</span> &middot; bestSim <span class='sim'>$bestSim</span> &middot; blur <span class='blur'>${blurPct}%</span><br>"
    echo "        subjectIdentified: $subj &middot; faces: $faceCount"
    echo "      </div>"
    echo "    </div>"
  done < "$TSV"

  cat <<HTML_TAIL
  </div>
</body>
</html>
HTML_TAIL
} > "$HTML"

echo ""
echo "summary: $TSV"
echo "html:    $HTML"
echo ""
open "$HTML"
