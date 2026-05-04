#!/bin/bash
# homefit.studio — simulator reset + fresh install
# Purpose: wipe Supabase session (so the app lands on the Sign-In screen),
# rebuild, and relaunch on the iPhone 16e simulator. Useful for brand
# screenshots and any time you want a "first launch" experience.
set -euo pipefail   # pipefail so `cmd | tail` doesn't mask cmd's failure

DEVICE=E4285EC5-6210-4D27-B3AF-F63ADDE139D9
BUNDLE=studio.homefit.app
APP_PATH=/Users/chm/dev/TrainMe/app/build/ios/iphonesimulator/Runner.app

echo "▸ Booting simulator (if not already booted)..."
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

echo "▸ Uninstalling existing app (clears Supabase session → back to Sign-In)..."
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true

echo "▸ Syncing web-player bundle into Flutter assets (R-10 parity)..."
# Without this, app/assets/web-player/* drifts behind web-player/* and
# the simulator preview ships stale bytes. Same step as install-device.sh.
cd /Users/chm/dev/TrainMe/app
dart run tool/sync_web_player_bundle.dart

echo "▸ Building Flutter app for simulator (first run ≈ 2-3 min)..."
cd /Users/chm/dev/TrainMe/app
# Bakes short git SHA into AppConfig.buildSha so the Pulse Mark footer
# renders a tiny muted build marker — lets us verify which commit is
# actually installed after a rebuild.
GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ios --debug --simulator --dart-define=GIT_SHA="$GIT_SHA"

echo "▸ Installing fresh build..."
xcrun simctl install "$DEVICE" "$APP_PATH"

echo "▸ Launching app..."
xcrun simctl launch "$DEVICE" "$BUNDLE"

echo "✓ Done. Simulator is on the Sign-In screen."
