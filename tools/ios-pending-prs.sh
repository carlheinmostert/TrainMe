#!/usr/bin/env bash
#
# tools/ios-pending-prs.sh
#
# List merged PRs labelled `ios-impact` since a given date (or since
# the last device install if you have a marker file). Designed for the
# multi-Claude-session workflow where one "deploy to phone" session
# wants to know which PRs other sessions have merged that require
# fresh iOS install.
#
# Usage:
#   tools/ios-pending-prs.sh                  # since 2 days ago
#   tools/ios-pending-prs.sh 2026-05-23       # since explicit date
#   tools/ios-pending-prs.sh 7d               # since N days ago (h/d/w)
#
# Output: one line per PR with title, branch, merge time, and a link.
#
# Pairs with the `ios-impact` label auto-applied by CI (see ci.yml
# label-ios-impact job). Sessions that touch real Dart / Swift /
# pubspec get the label; web-player-only PRs do not.

set -euo pipefail

since="${1:-2d}"

# Normalise: if the arg is `Nd` / `Nh` / `Nw`, convert to ISO date.
if [[ "$since" =~ ^([0-9]+)([dhw])$ ]]; then
  n="${BASH_REMATCH[1]}"
  u="${BASH_REMATCH[2]}"
  case "$u" in
    h) since="$(date -u -v "-${n}H" +%Y-%m-%dT%H:%M:%SZ)" ;;
    d) since="$(date -u -v "-${n}d" +%Y-%m-%d)" ;;
    w) since="$(date -u -v "-${n}w" +%Y-%m-%d)" ;;
  esac
fi

echo "→ Merged PRs labelled 'ios-impact' since $since:"
echo

# Use --json + --template so we get a tidy printable list. gh's default
# list output is fine but the template is more diff-friendly when piped
# into a build-and-install script.
gh pr list \
  --label ios-impact \
  --state merged \
  --search "merged:>=${since}" \
  --json number,title,headRefName,mergedAt,url \
  --template '{{range .}}#{{.number}}  {{.title}}
   branch: {{.headRefName}}
   merged: {{timeago .mergedAt}}
   url:    {{.url}}

{{end}}'

count="$(gh pr list \
  --label ios-impact \
  --state merged \
  --search "merged:>=${since}" \
  --json number \
  --jq 'length')"

echo "Total: ${count} PRs."

if [[ "$count" -gt 0 ]]; then
  echo
  echo "Next step: ./install-device.sh staging  (or homefit-install-device skill)"
fi
