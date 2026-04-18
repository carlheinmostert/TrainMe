#!/bin/bash
# homefit.studio — simulator reset + fresh install
# Purpose: wipe Supabase session (so the app lands on the Sign-In screen),
# rebuild, and relaunch on the iPhone 16e simulator. Useful for brand
# screenshots and any time you want a "first launch" experience.
set -e

DEVICE=E4285EC5-6210-4D27-B3AF-F63ADDE139D9
BUNDLE=com.raidme.raidme
APP_PATH=/Users/chm/dev/TrainMe/app/build/ios/iphonesimulator/Runner.app

echo "▸ Booting simulator (if not already booted)..."
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

echo "▸ Uninstalling existing app (clears Supabase session → back to Sign-In)..."
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true

echo "▸ Building Flutter app for simulator (first run ≈ 2-3 min)..."
cd /Users/chm/dev/TrainMe/app
LC_ALL=en_US.UTF-8 flutter build ios --debug --simulator

echo "▸ Installing fresh build..."
xcrun simctl install "$DEVICE" "$APP_PATH"

echo "▸ Launching app..."
xcrun simctl launch "$DEVICE" "$BUNDLE"

echo "✓ Done. Simulator is on the Sign-In screen."
