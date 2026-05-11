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
#   ./bump-version.sh --no-tag         # bump pubspec only (legacy behaviour)
#   ./bump-version.sh build --no-tag   # same, with explicit kind
#
# Apple TestFlight rejects duplicate build numbers within the same marketing
# version, so the build counter must climb on every upload. Run this from
# anywhere — it anchors itself on the script's own directory.
#
# By default the script also commits the pubspec change and creates an
# annotated `mobile-v{version}+{build}` git tag, then pushes the tag to
# origin so every TestFlight upload has a discoverable git anchor. Pass
# `--no-tag` to skip the commit + tag step (legacy behaviour, useful when
# bundling the bump into a larger commit by hand).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBSPEC="${SCRIPT_DIR}/app/pubspec.yaml"

if [[ ! -f "$PUBSPEC" ]]; then
  echo "error: cannot find $PUBSPEC" >&2
  exit 1
fi

# Parse args. Accept the kind in any position; --no-tag (or --no-commit,
# its alias) anywhere. Keep flag-parsing forgiving — TestFlight day is no
# time for argparse pedantry.
bump_kind=""
do_tag=1
for arg in "$@"; do
  case "${arg#--}" in
    no-tag|no-commit)
      do_tag=0
      ;;
    build|major|minor|patch)
      bump_kind="${arg#--}"
      ;;
    *)
      echo "error: unknown argument: $arg (expected: build | major | minor | patch | --no-tag)" >&2
      exit 2
      ;;
  esac
done
bump_kind="${bump_kind:-build}"

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

# Commit + tag the bump so every TestFlight upload has a discoverable git
# anchor. Skip with --no-tag for users who want to bundle the bump into a
# larger commit themselves.
if (( do_tag )); then
  # Pull the new X.Y.Z+N off the rewritten line.
  new_version=$(printf '%s\n' "$after" | sed 's/^version:[[:space:]]*//')
  tag="mobile-v${new_version}"

  echo
  # Refuse to run outside a git checkout.
  if ! git -C "$SCRIPT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    echo "▸ Not inside a git repo — skipping commit + tag." >&2
    echo "  (Re-run inside a checkout, or pass --no-tag explicitly to silence this.)"
    exit 0
  fi

  # Refuse to bury an unrelated dirty working tree in the bump commit.
  # Only pubspec.yaml may be modified; anything else means the user has
  # in-flight work that they should commit first.
  other_changes=$(git -C "$SCRIPT_DIR" status --porcelain | grep -v ' app/pubspec.yaml$' || true)
  if [[ -n "$other_changes" ]]; then
    echo "error: refusing to commit + tag — working tree has unrelated changes:" >&2
    printf '%s\n' "$other_changes" >&2
    echo
    echo "  Commit / stash those first, or pass --no-tag to bump pubspec only." >&2
    exit 3
  fi

  # If the tag already exists locally or on origin, bail loudly rather
  # than overwrite (TestFlight build numbers are immutable; a duplicate
  # tag would point at the wrong commit forever).
  if git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/${tag}" > /dev/null; then
    echo "error: local tag ${tag} already exists — refusing to overwrite." >&2
    echo "  Delete it with \`git tag -d ${tag}\` if you're sure." >&2
    exit 4
  fi
  if git -C "$SCRIPT_DIR" ls-remote --tags origin "refs/tags/${tag}" | grep -q .; then
    echo "error: remote tag ${tag} already exists on origin — refusing to overwrite." >&2
    echo "  Bump again, or delete it with \`git push --delete origin ${tag}\`." >&2
    exit 5
  fi

  echo "▸ Committing bump + tagging ${tag}"
  git -C "$SCRIPT_DIR" add app/pubspec.yaml
  git -C "$SCRIPT_DIR" commit -m "chore(testflight): bump to ${new_version}"
  git -C "$SCRIPT_DIR" tag -a "${tag}" -m "TestFlight build ${new_version}"
  echo "▸ Pushing tag to origin"
  git -C "$SCRIPT_DIR" push origin "${tag}"
  echo "▸ Done — ${tag} now points at HEAD."
fi

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
