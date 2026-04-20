#!/bin/bash
# homefit.studio — physical device install (iPhone CHM)
#
# Purpose: pull latest main, build, install on your physical iPhone.
#
# As of 2026-04-18, NordVPN + Xcode device tunnel coexist — run this
# straight through, no VPN dance. iPhone plugged in via USB + unlocked
# is all that's needed. If device-tunnel ever regresses after a NordVPN
# update, the historic workaround was "VPN off for the install window";
# see memory/vpn_api_constraint.md.
set -e

DEVICE=00008150-001A31D40E88401C   # iPhone CHM
BUNDLE=com.raidme.raidme
APP_PATH=/Users/chm/dev/TrainMe/app/build/ios/iphoneos/Runner.app

echo "▸ Pulling latest main..."
cd /Users/chm/dev/TrainMe
git pull origin main

echo "▸ Building Flutter app for physical device in PROFILE mode (first run ≈ 5-8 min)..."
# Profile mode — not release — during QA. Debug mode is rejected by iOS
# 14+ for standalone launch ("Cannot create a FlutterEngine instance in
# debug mode without Flutter tooling or Xcode"), but PROFILE is AOT-
# compiled AND retains `debugPrint` / stdout so logs still show up via
# `idevicesyslog`. Release mode strips those, which made us blind when
# diagnosing the raw-archive silent upload failure (2026-04-20).
#
# Passing the current short git SHA via --dart-define bakes it into
# AppConfig.buildSha, which the Settings footer (post-Wave-3) renders
# as a tiny muted label. Confirms at a glance which commit is on-device
# after a rebuild.
cd /Users/chm/dev/TrainMe/app
GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ios --profile --dart-define=GIT_SHA="$GIT_SHA"

echo "▸ Installing to iPhone CHM..."
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"

echo "✓ Done. Open homefit.studio on your phone — it will be on the Sign-In screen (fresh session)."
