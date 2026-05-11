#!/bin/bash
# bump-version.sh — increment app/pubspec.yaml version for the next TestFlight upload.
#
# Usage:
#   ./bump-version.sh              # default — bumps build number (+N)
#   ./bump-version.sh build        # explicit build-number bump
#   ./bump-version.sh patch        # bumps Z in X.Y.Z, resets +N to +1
#   ./bump-version.sh minor        # bumps Y, resets Z=0 +N=+1
#   ./bump-version.sh major        # bumps X, resets Y=0 Z=0 +N=+1
#
# Apple TestFlight rejects duplicate build numbers within the same marketing
# version, so the build counter must climb on every upload. Run this from
# anywhere — it anchors itself on the script's own directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBSPEC="${SCRIPT_DIR}/app/pubspec.yaml"

if [[ ! -f "$PUBSPEC" ]]; then
  echo "error: cannot find $PUBSPEC" >&2
  exit 1
fi

# Strip a leading -- from the flag so both `--patch` and `patch` work.
raw_kind="${1:-build}"
bump_kind="${raw_kind#--}"

case "$bump_kind" in
  build|major|minor|patch) ;;
  *)
    echo "error: unknown bump kind: $raw_kind (expected: build | major | minor | patch)" >&2
    exit 2
    ;;
esac

before=$(grep '^version:' "$PUBSPEC")

python3 - "$PUBSPEC" "$bump_kind" <<'PY'
import re
import sys
import pathlib

path, kind = sys.argv[1], sys.argv[2]
text = pathlib.Path(path).read_text()
m = re.search(r'^version:\s+(\d+)\.(\d+)\.(\d+)\+(\d+)', text, re.M)
if not m:
    sys.exit("error: could not find version line matching X.Y.Z+N")

major, minor, patch, build = (int(g) for g in m.groups())

if kind == "build":
    build += 1
elif kind == "patch":
    patch += 1
    build = 1
elif kind == "minor":
    minor += 1
    patch = 0
    build = 1
elif kind == "major":
    major += 1
    minor = 0
    patch = 0
    build = 1

new_line = f"version: {major}.{minor}.{patch}+{build}"
text = re.sub(r'^version:.*$', new_line, text, count=1, flags=re.M)
pathlib.Path(path).write_text(text)
PY

after=$(grep '^version:' "$PUBSPEC")

echo "▸ Bumped: $before  →  $after"
echo
echo "Next:"
echo "  Option A (CLI — explicit ENV=prod):"
echo "    ./build-testflight.sh         # produces a prod-pointed IPA"
echo
echo "  Option B (Xcode Archive):"
echo "    1. Open Xcode at app/ios/Runner.xcworkspace"
echo "    2. Product → Archive → Upload to App Store Connect"
echo "    (AppConfig.env defaults to 'prod' when no --dart-define is"
echo "     passed, so Xcode Archive is also a safe prod build path.)"
