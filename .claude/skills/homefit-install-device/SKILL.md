---
name: homefit-install-device
description: Build the Flutter app and install on Carl's iPhone CHM directly, without going through install-device.sh. Uses a sticky persistent worktree at .claude/worktrees/iphone-install so Xcode DerivedData survives across builds. Default build mode is profile (the only standalone-on-device option without a Flutter debugger attached). Faster than the legacy script because it skips flutter clean unless dependencies actually changed and keeps the source tree stable. Use when Carl says "install to phone", "ship to iphone", "deploy to phone", "build + install", or as the install step inside homefit-ship-to-phone.
---

# homefit-install-device

Direct Flutter build + `xcrun devicectl` install on the iPhone CHM (`00008150-001A31D40E88401C`). Supersedes calling `./install-device.sh` for routine QA iteration. Carl wants this path because the script's per-call worktree churn invalidated Xcode DerivedData on every install — cold-build penalty every time, even for code-only commits.

## Inputs

- Branch: default `staging`. Override with the explicit branch arg if Carl says otherwise.
- Build mode: **default `profile`.** This is the ONLY standalone-on-device-iOS mode that works without `flutter run` attached. `--debug` on iOS device produces a binary that white-screens on launch because Apple forbids JIT execution outside a debugger session — the embedded Dart VM can't start. Honour Carl's explicit override (e.g. `--release` for TestFlight, or `--debug` only if he confirms he'll attach `flutter run` after install).
- iPhone CHM UDID: `00008150-001A31D40E88401C`.
- Staging Supabase project ref: `vadjvkmldtoeyspyoqbx` → URL `https://vadjvkmldtoeyspyoqbx.supabase.co`.
- Prod Supabase project ref: `yrwcofhovrcydootivjx`.

## Workflow

### 1. Resolve build mode

**If the skill invocation included an explicit mode argument (`debug` or `profile`), use it directly. Skip the question.** Examples:

- `Use Skill homefit-install-device with args "debug"` → no question, build debug.
- `Use Skill homefit-install-device with args "profile"` → no question, build profile.

**Only ask when the argument is missing or ambiguous.** Use `AskUserQuestion`:

```
question: "Build mode for the iPhone install?"
header: "Build mode"
options:
  - label: "Debug (Recommended)"
    description: "Skips Dart AOT — ~2-3 min faster build. Runtime perf is invisible for QA iteration."
  - label: "Profile"
    description: "Full AOT compile. Slower (~5-10 min) but production-like perf. Use before TestFlight uploads or perf testing."
multiSelect: false
```

Use Carl's answer to pick `--debug` or `--profile`. The default selection is debug — that's the right answer 95% of the time for QA work.

### 2. Ensure the sticky build worktree exists

The worktree lives at `.claude/worktrees/iphone-install` and is permanent — DerivedData reuse depends on this path staying stable. **Never** `git worktree remove` it as a cleanup step.

```bash
WT=/Users/chm/dev/TrainMe/.claude/worktrees/iphone-install
if [ ! -d "$WT" ]; then
  git worktree add "$WT" origin/staging
fi
cd "$WT"
git fetch origin staging
# Hard reset because the worktree may carry over local state from a previous
# uncommitted poke (config edits, half-applied tweaks). The branch tip is the
# canonical source.
git reset --hard origin/staging
SHA=$(git rev-parse --short HEAD)
```

### 3. Decide whether dependencies need refresh

Compare current `pubspec.lock` + `ios/Podfile.lock` against the last successful build's hashes (cached at `$WT/.last_iphone_install_deps_hash`). Skip `flutter pub get` / `pod install` if both match.

```bash
# pod install (CocoaPods/Ruby) crashes with
# `Encoding::CompatibilityError (ASCII-8BIT)` when the shell has no UTF-8
# locale — which is the case in a non-interactive / background Bash shell
# (the interactive terminal that runs install-device.sh has LANG set, so
# this only bites the agent path). Export it unconditionally before pod.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
DEPS_HASH=$(shasum -a 256 app/pubspec.lock app/ios/Podfile.lock 2>/dev/null | shasum -a 256 | cut -c1-16)
LAST_DEPS_HASH=$(cat app/.last_iphone_install_deps_hash 2>/dev/null || echo "")
if [ "$DEPS_HASH" != "$LAST_DEPS_HASH" ]; then
  cd app && flutter pub get
  cd ios && pod install --silent
  cd ..
fi
```

### 4. Decide whether the web-player bundle needs syncing

If `web-player/` has changed since the last build, run the sync. Otherwise skip — it's a no-op pure-copy step but Dart startup is ~3s on its own.

```bash
WP_HASH=$(find web-player -type f -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.json' | sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-16)
LAST_WP_HASH=$(cat app/.last_iphone_install_webplayer_hash 2>/dev/null || echo "")
if [ "$WP_HASH" != "$LAST_WP_HASH" ]; then
  cd app && dart run tool/sync_web_player_bundle.dart && cd ..
  echo "$WP_HASH" > app/.last_iphone_install_webplayer_hash
fi
```

### 5. Fetch the Supabase anon key for staging

Same mechanism as `install-device.sh` — `supabase projects api-keys` via the CLI:

```bash
ANON_KEY=$(supabase projects api-keys --project-ref vadjvkmldtoeyspyoqbx --output json \
  | python3 -c "import sys,json; ks=json.load(sys.stdin); [print(k['api_key']) for k in ks if k.get('name')=='anon'][0]")
```

If this fails (CLI not logged in, network down), abort with a clear error: `Could not fetch staging anon key — run \`supabase login\` and retry`. Do NOT silently fall back to a stale value.

### 6. Build

```bash
cd app
flutter build ios --<MODE> \
  --dart-define=GIT_SHA="$SHA" \
  --dart-define=ENV=staging \
  --dart-define=SUPABASE_URL="https://vadjvkmldtoeyspyoqbx.supabase.co" \
  --dart-define=SUPABASE_ANON_KEY="$ANON_KEY"
```

Where `<MODE>` is `debug` or `profile` per step 1. **Do NOT pass `--simulator`** — that would build for the iOS simulator architecture (x86_64/arm64-sim) and the install would fail on the physical iPhone.

On first run after `flutter pub get` / `pod install` from step 3, this will be a cold build (~5-10 min for debug, ~10-15 min for profile). Subsequent builds reuse DerivedData and run in ~30s to 2 min.

After successful build:

```bash
echo "$DEPS_HASH" > app/.last_iphone_install_deps_hash
```

### 7. Install on iPhone CHM

The build output lives at `app/build/ios/iphoneos/Runner.app` (the device-arch build — no `Debug-iphoneos` subdirectory ambiguity for the Flutter build script).

```bash
APP=app/build/ios/iphoneos/Runner.app
xcrun devicectl device install app --device 00008150-001A31D40E88401C "$APP"
```

If the device is not connected (`devicectl` returns "no matching device"), surface the error and STOP. Do not loop.

### 8. Report back

Reply to Carl with:
- The build SHA + mode: `Installed 6a12b31 (debug) on iPhone CHM.`
- How long the build took.
- **A list of `ios-impact`-labelled merged PRs this install covers**, queried via `tools/ios-pending-prs.sh` (default lookback 2 days, or since the last `app/.last_iphone_install_deps_hash` mtime, whichever is more recent). One line per PR. This is the audit trail — Carl can confirm the install bundled the work he expected.
- The next test step if invoked inside `homefit-ship-to-phone`, OR just the SHA confirmation + PR list if invoked standalone.

## Why this is faster than `install-device.sh`

1. **Sticky source tree.** The script creates + tears down a fresh worktree per call → `~/Library/Developer/Xcode/DerivedData/Runner-*` invalidates → every build is cold. This skill reuses one stable worktree, so Xcode incremental build engages.
2. **Lazy dependency refresh.** `flutter pub get` + `pod install` only run when `pubspec.lock` / `Podfile.lock` actually changed. The script always does them.
3. **Debug by default.** `flutter build ios --debug` skips the Dart AOT tree-shake (~2-3 min). The script defaults to `--profile`.
4. **No `flutter clean` triggered by SHA changes.** The script's fingerprint-based `flutter clean` invalidates the whole build cache on every commit. This skill only cleans when dependencies actually shifted.

Combined: cold build ~3-4 min (was ~10 min). Warm build ~30s-1 min (was ~5 min).

## Don'ts

- Don't `git worktree remove` the sticky worktree. It's permanent by design.
- Don't pass `--simulator` to `flutter build ios`. This skill ships to a physical device.
- Don't skip the build-mode question. Always ask.
- Don't fall back silently when the Supabase anon key fetch fails — hard error.
- Don't use this skill for TestFlight uploads. That's a separate `--release` build path with code signing for distribution.

## Encodes

- `feedback_no_silent_fallbacks` — anon key fetch failure is a hard error, not a silent default.
- `feedback_long_agent_checkins` — when invoked with run-in-background, poll the build progress per-minute and post one-line updates.

## Related

- `homefit-ship-to-phone` — orchestrates this skill + test-script authoring + WhatsApp ping after device install.
- `docs/BACKLOG.md` — "iPhone build-speed pass" entry that motivated this skill.
