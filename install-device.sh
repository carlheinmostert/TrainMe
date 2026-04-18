#!/bin/bash
# homefit.studio — physical device install (iPhone CHM)
#
# Purpose: pull latest main, build, install on your physical iPhone.
# Run this SOLO (Claude's API isn't reachable while VPN is off).
#
# VPN dance:
#   1. Disconnect NordVPN before running this script (Xcode's device
#      tunnel breaks when NordVPN is on, per experience).
#   2. Make sure your iPhone is plugged in via USB and unlocked.
#   3. Run ./install-device.sh
#   4. When the script finishes, reconnect VPN.
#   5. Tell Claude "device install done" — Claude can't see anything
#      that happened while you were offline.
set -e

DEVICE=00008150-001A31D40E88401C   # iPhone CHM
BUNDLE=com.raidme.raidme
APP_PATH=/Users/chm/dev/TrainMe/app/build/ios/iphoneos/Runner.app

echo "▸ Pulling latest main..."
cd /Users/chm/dev/TrainMe
git pull origin main

echo "▸ Building Flutter app for physical device in RELEASE mode (first run ≈ 5-8 min)..."
# Release build is required for physical-device standalone launch — iOS 14+
# rejects debug-mode Flutter binaries launched outside of `flutter run`
# ("Cannot create a FlutterEngine instance in debug mode without Flutter
#  tooling or Xcode"). Release strips debug symbols, compiles AOT, and
# produces a binary the device can launch from the home screen on its own.
#
# Passing the current short git SHA via --dart-define bakes it into
# AppConfig.buildSha, which the Pulse Mark footer renders as a tiny
# muted label in the bottom-right. Confirms at a glance which commit
# is on-device after a rebuild.
cd /Users/chm/dev/TrainMe/app
GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ios --release --dart-define=GIT_SHA="$GIT_SHA"

echo "▸ Installing to iPhone CHM..."
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"

echo "✓ Done. Open homefit.studio on your phone — it will be on the Sign-In screen (fresh session)."
echo ""
echo "Reminder: reconnect your VPN before coming back to Claude."
