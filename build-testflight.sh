#!/bin/bash
# homefit.studio — TestFlight release build
#
# Purpose: produce a prod-pointed IPA ready to upload to App Store
# Connect. Explicitly pins ENV=prod with the hardcoded prod Supabase
# project URL + anon key so TestFlight builds NEVER accidentally point
# at staging or a feature-branch DB.
#
# Usage:
#   ./bump-version.sh patch        # bump the version first
#   ./build-testflight.sh          # produces app/build/ios/ipa/*.ipa
#
# Then upload the IPA via Transporter, `xcrun altool`, or Xcode's
# Organizer. Or open `app/ios/Runner.xcworkspace` and Archive — the
# AppConfig prod defaults mean Xcode Archive ALSO ships a prod-pointed
# build (defence in depth), but this CLI path is the explicit one.
#
# See docs/CI.md §5 for the ENV three-way (prod / staging / branch).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hardcoded prod values — match AppConfig._prodSupabaseUrl /
# _prodSupabaseAnonKey. Defence in depth: AppConfig.env defaults to
# 'prod' too, so even a build that doesn't pass --dart-define=ENV=prod
# still picks up these values via the static fallback. But passing them
# explicitly here is load-bearing — it's the documented release path
# and makes the CI artefact deterministic.
PROD_SUPABASE_URL='https://yrwcofhovrcydootivjx.supabase.co'
PROD_SUPABASE_ANON_KEY='sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3'

echo "▸ Confirming current branch is main (TestFlight builds ship main only)..."
current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "main" ]]; then
  echo "WARNING: current branch is '$current_branch', not 'main'." >&2
  echo "         TestFlight builds should normally ship main only." >&2
  echo "         Press Ctrl-C to abort, or wait 5s to continue..." >&2
  sleep 5
fi

echo "▸ Syncing web-player bundle into Flutter assets (R-10 parity)..."
cd "${REPO_ROOT}/app"
dart run tool/sync_web_player_bundle.dart

echo "▸ Building release IPA with ENV=prod..."
cd "${REPO_ROOT}/app"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ipa --release \
  --dart-define=GIT_SHA="$GIT_SHA" \
  --dart-define=ENV=prod \
  --dart-define=SUPABASE_URL="$PROD_SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$PROD_SUPABASE_ANON_KEY"

IPA_DIR="${REPO_ROOT}/app/build/ios/ipa"
echo "✓ Done. IPA(s) at: $IPA_DIR"
ls -la "$IPA_DIR" 2>/dev/null || true
echo
echo "Next:"
echo "  - Upload via Transporter, \`xcrun altool --upload-app\`, or Xcode Organizer."
echo "  - Or open app/ios/Runner.xcworkspace → Product → Archive (AppConfig"
echo "    prod defaults make this safe too — see docs/CI.md §5)."
