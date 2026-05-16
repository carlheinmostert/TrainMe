#!/usr/bin/env bash
# check-hero-resolver.sh
# ----------------------------------------------------------------------------
# Enforces the "hero resolver is the single source of truth" rule from
# docs/HERO_RESOLVER.md and the feedback_hero_resolver_single_source.md
# memory.
#
# All hero-image rendering on every surface — Studio card, filmstrip,
# camera peek, web-player lobby, web-player PDF export — must go through
# the hero resolver:
#   - web-player/hero_resolver.js
#   - app/lib/services/exercise_hero_resolver.dart (Flutter; partial today)
#   - app/lib/utils/hero_crop_alignment.dart (centralised Alignment helper)
#
# Forbidden patterns (each fails with a clear pointer to docs/HERO_RESOLVER.md):
#
#   1. `object-fit: cover` on `.lobby-hero-media` (the <img> selector).
#      The data URL produced by the resolver is already 1:1; object-fit
#      is dead weight on <img> and html2canvas would ignore it anyway,
#      silently regressing PDF export. Exception: `video.lobby-hero-media`
#      is allowed — video frames stream at source aspect ratio.
#
#   2. `heroCropOffset` reads outside the resolver / model / editor /
#      data-access wire layer. New readers are migration targets; even
#      today every reader has to redo the clamp + axis-pick logic.
#
#   3. Static `_thumb*.jpg` <img> tags in lobby code or PDF code that
#      bypass hydrateHeroCrops. A direct thumbnail-URL <img> silently
#      rolls back to "uncropped image cropped by CSS" — the exact
#      pre-PR-#364 state.
#
# Each rule scans BOTH `web-player/` AND `app/assets/web-player/` (the
# Flutter-bundled mirror — sync drift could land there too).
#
# Usage
# -----
#   scripts/ci/check-hero-resolver.sh
#
# Exit codes:
#   0 - clean (no violations)
#   1 - violations found
# ----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

DOC_REF="docs/HERO_RESOLVER.md"

# Files allowed to READ `heroCropOffset` for any reason — the resolver
# modules, the model, the editor, and the data-access wire layer.
# Stored as exact repo-relative paths. Test files are auto-allowed
# (any path matching the patterns below).
HEROCROP_ALLOWED_EXACT=(
  "web-player/hero_resolver.js"
  "app/lib/services/exercise_hero_resolver.dart"
  "app/lib/utils/hero_crop_alignment.dart"
  "app/lib/models/exercise_capture.dart"
  "app/lib/widgets/hero_crop_viewport.dart"
  "app/lib/screens/studio_mode_screen.dart"
  "app/lib/widgets/exercise_editor_sheet.dart"
  "app/lib/services/upload_service.dart"
  "app/lib/services/sync_service.dart"
  "app/lib/services/unified_preview_scheme_bridge.dart"
)

is_herocrop_allowed() {
  local path="$1"
  for exact in "${HEROCROP_ALLOWED_EXACT[@]}"; do
    if [[ "${path}" == "${exact}" ]]; then
      return 0
    fi
  done
  # Test files / mocks / generated.
  case "${path}" in
    */test/*|*_test.dart|*.mocks.dart|*.g.dart|*.freezed.dart) return 0 ;;
  esac
  return 1
}

violations=()

# ---------------------------------------------------------------------------
# Rule 1: forbid `object-fit: cover` on `.lobby-hero-media` (the <img>
# selector). The `video.lobby-hero-media` selector is explicitly allowed
# (documented in web-player/styles.css head-of-rule comment).
#
# Implementation: walk styles.css line-by-line; track whether the current
# CSS rule block was opened by a selector that contained
# `.lobby-hero-media` WITHOUT a `video.lobby-hero-media` qualifier on
# that same selector list. If yes AND we see `object-fit: cover` inside
# the block, flag it.
# ---------------------------------------------------------------------------
scan_lobby_hero_object_fit() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    return
  fi

  python3 - "${path}" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Tiny CSS state machine. Walk every line. When a rule opens (`{`),
# capture the accumulated selector text. If the selector mentions
# `.lobby-hero-media` AND does NOT mention `video.lobby-hero-media`,
# the block is in "img-style mode" and `object-fit: cover` inside it
# is forbidden. The selector buffer carries multi-line selector heads
# (the codebase uses a few comma-separated selectors split across
# lines).
#
# This is grep-with-context — not a real CSS parser — but sufficient
# for the well-formed selector lists in this codebase. The legitimate
# exception (`video.lobby-hero-media { object-fit: cover; }`) sits on
# its own selector and is allowed.
violations = []
buf = ''
i = 0
while i < len(lines):
    line = lines[i]
    if '{' in line and '}' not in line:
        # Rule opens on this line. Selector is everything before `{`
        # in `buf + line` (multi-line selector heads accumulate in
        # `buf` until the brace lands).
        head, _, _ = (buf + line).rpartition('{')
        selector_text = head
        buf = ''
        mentions = '.lobby-hero-media' in selector_text
        video_qualified = 'video.lobby-hero-media' in selector_text
        block_is_img_style = mentions and not video_qualified
        # Walk the body until the matching close-brace (nested-brace
        # depth supported for safety even though CSS doesn't nest).
        depth = 1
        j = i + 1
        while j < len(lines) and depth > 0:
            l = lines[j]
            depth += l.count('{')
            depth -= l.count('}')
            if block_is_img_style and re.search(r'object-fit\s*:\s*cover', l):
                violations.append((j + 1, l.strip()))
            j += 1
        i = j
        continue
    if '{' in line and '}' in line:
        # Single-line rule. Selector + body + close on one line.
        head, _, rest = line.partition('{')
        body, _, _ = rest.partition('}')
        mentions = '.lobby-hero-media' in (buf + head)
        video_qualified = 'video.lobby-hero-media' in (buf + head)
        block_is_img_style = mentions and not video_qualified
        if block_is_img_style and re.search(r'object-fit\s*:\s*cover', body):
            violations.append((i + 1, line.strip()))
        buf = ''
        i += 1
        continue
    # Accumulate multi-line selector head.
    if '}' not in line:
        buf += line
    i += 1

for lineno, content in violations:
    print(f'{path}:{lineno}:object-fit: cover on .lobby-hero-media: {content}')
PY
}

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  violations+=("${line}")
done < <(
  scan_lobby_hero_object_fit "web-player/styles.css"
  scan_lobby_hero_object_fit "app/assets/web-player/styles.css"
)

# ---------------------------------------------------------------------------
# Rule 2: forbid `heroCropOffset` reads outside the allowed Flutter files.
# Wire-format JSON keys (`hero_crop_offset` as a string) inside the data-
# access layer's wire-format paths are not scanned — those are already on
# the allow-list.
# ---------------------------------------------------------------------------
while IFS= read -r path; do
  [[ -z "${path}" ]] && continue
  if is_herocrop_allowed "${path}"; then
    continue
  fi
  hits="$(grep -nE 'heroCropOffset' "${path}" 2>/dev/null || true)"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r hit; do
      [[ -z "${hit}" ]] && continue
      lineno="${hit%%:*}"
      content="${hit#*:}"
      # Skip pure-comment lines so doc references don't trip the check.
      stripped="$(echo "${content}" | sed 's/^[[:space:]]*//')"
      case "${stripped}" in
        //*|/\**|\**|\*\/*|'///'*) continue ;;
      esac
      violations+=("${path}:${lineno}:heroCropOffset read outside allow-list: ${stripped}")
    done <<< "${hits}"
  fi
done < <(find app/lib -type f -name '*.dart' 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Rule 3: forbid static `_thumb*.jpg` <img class="lobby-hero-media" src=>
# tags in lobby code that bypass hydrateHeroCrops. The resolver swap is
# the only path. After hydrateHeroCrops, the live `src` is a data URL —
# so the static-`_thumb` pattern matches exactly the bypass case.
#
# Pattern: a string literal that contains `lobby-hero-media` AND `_thumb`
# AND `src=` on the same physical line. We scan lobby.js + lobby.js in
# the asset mirror.
# ---------------------------------------------------------------------------
scan_static_thumb_img() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    return
  fi
  # Match lines that look like `<img ... src="..._thumb...">` AND mention
  # lobby-hero-media on the same line. The hydrateHeroCrops path uses
  # `data-hero-source` (not a literal `src="..._thumb"`), so legitimate
  # paths won't trip this.
  grep -nE '<img[^>]*lobby-hero-media[^>]*src="[^"]*_thumb' "${path}" 2>/dev/null || true
}

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  path="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"
  violations+=("${path}:${lineno}:static _thumb img bypasses hydrateHeroCrops: ${content}")
done < <(
  hits="$(scan_static_thumb_img "web-player/lobby.js")"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r h; do
      [[ -n "${h}" ]] && echo "web-player/lobby.js:${h}"
    done <<< "${hits}"
  fi
  hits="$(scan_static_thumb_img "app/assets/web-player/lobby.js")"
  if [[ -n "${hits}" ]]; then
    while IFS= read -r h; do
      [[ -n "${h}" ]] && echo "app/assets/web-player/lobby.js:${h}"
    done <<< "${hits}"
  fi
)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ ${#violations[@]} -eq 0 ]]; then
  echo "OK: hero-resolver single-source-of-truth rule clean."
  exit 0
fi

echo "ERROR: ${#violations[@]} hero-resolver rule violation(s) found."
echo ""
echo "All hero-image rendering must go through the hero resolver."
echo "See ${DOC_REF} for the rule + the forbidden-patterns table."
echo ""
echo "Resolver entry points:"
echo "  Web:     window.HomefitHeroResolver.getHeroSquareImage(...)  (web-player/hero_resolver.js)"
echo "  Flutter: heroCropAlignment(exercise)                         (app/lib/utils/hero_crop_alignment.dart)"
echo ""
echo "Violations:"
for v in "${violations[@]}"; do
  echo "  ${v}"
done
exit 1
