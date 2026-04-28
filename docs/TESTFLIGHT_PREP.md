# TestFlight Prep — Bundle ID + First Upload

**Status:** ready for first upload, pending Apple Developer Program activation.
**Date:** 2026-04-28

## Bundle ID — LOCKED

The iOS app ships under bundle ID **`studio.homefit.app`** (reverse-DNS form
of the `homefit.studio` brand). This was rebranded from the legacy codename
`com.raidme.raidme` on 2026-04-28 — see commit `chore(ios): rebrand bundle
ID com.raidme.raidme → studio.homefit.app`.

**Why now:** App Store Connect bundle IDs are immutable the moment a record
is created. Carl had not yet created the App Store Connect record at the
point of the rebrand, so this was the last clean window. Any new App Store
Connect record MUST be created with `studio.homefit.app` from day one.

The test target follows convention: `studio.homefit.app.RunnerTests`.

## What changed in the rebrand

1. `app/ios/Runner.xcodeproj/project.pbxproj` — six `PRODUCT_BUNDLE_IDENTIFIER`
   lines (Runner × Debug/Release/Profile + RunnerTests × Debug/Release/Profile).
2. `app/ios/Runner/Info.plist` — `CFBundleURLSchemes` now `studio.homefit.app`
   (CFBundleURLName "homefit.studio OAuth Callback" stays).
3. `app/pubspec.yaml` — `version: 0.1.0+1` → `version: 1.0.0+1` for first
   TestFlight upload. Marketing version 1.0.0; build number starts at 1.
4. `app/lib/config.dart` — `AppConfig.oauthRedirectUrl` =
   `studio.homefit.app://login-callback`.
5. `app/lib/services/auth_service.dart` — comment updated to match.
6. `app/ios/Runner/AvatarCameraChannel.swift`,
   `app/ios/Runner/ClientAvatarProcessor.swift` — `os_log` subsystem strings
   bumped to `studio.homefit.app` (Console.app filter strings; see Diagnostics
   note below).
7. `app/lib/screens/client_avatar_capture_screen.dart` — comment updated.
8. `install-sim.sh`, `install-device.sh` — `BUNDLE=studio.homefit.app`.
9. `CLAUDE.md` — Simulator Testing Notes launch line + new Backlog entry for
   SIWA/Google re-enablement allowlist work.
10. `docs/BACKLOG_GOOGLE_SIGNIN.md` — appended a "Bundle ID rebrand
    follow-up" section.

## What did NOT change

- Display name, bundle name strings — already `homefit.studio` / `homefit`.
- Web portal (`manage.homefit.studio`), web player (`session.homefit.studio`)
  — they reference HTTPS URLs, not bundle IDs.
- Supabase database, RLS, RPCs — the bundle ID has no representation in the
  database.
- macOS + Android build configs — out of scope for the TestFlight push (iOS
  only for MVP per `CLAUDE.md`). When Android ships, repeat the rebrand on
  `app/android/app/build.gradle.kts` + the `app/android/app/src/main/kotlin/`
  package directory.
- Existing `docs/test-scripts/2026-04-27-wave3*.html` — historical record,
  Carl's QA filter strings at the time. New test scripts going forward should
  use `studio.homefit.app`.

## Supabase auth redirect allowlist

Per `CLAUDE.md` the current allowlist is:

- `https://manage.homefit.studio/**`
- `http://localhost:3000/**`

The mobile app currently uses **magic-link HTTPS deeplinks**, not a custom
URL scheme, so the allowlist does NOT need a `studio.homefit.app://` entry
today. When Google or Apple Sign-In is re-enabled (see
`docs/BACKLOG_GOOGLE_SIGNIN.md`), `studio.homefit.app://` must be added to:

1. The Supabase auth redirect allowlist.
2. The Google Cloud Console iOS OAuth client (regenerate against the new
   bundle ID).
3. The Apple Sign-In Service ID return-URL config.

## Diagnostics — Console.app filter

If filtering iOS Flutter profile/release builds in Console.app, the
subsystem string is now `studio.homefit.app` (was `com.raidme.raidme`).
Category strings (`avatar.capture` etc.) are unchanged.

Example Console.app filter:
`subsystem:studio.homefit.app category:avatar.capture`

## First TestFlight upload checklist (Carl)

After the rebrand merges:

1. `./install-sim.sh` — confirms simulator launch under
   `studio.homefit.app` works end-to-end.
2. `xcrun simctl launch <device-id> studio.homefit.app` — sanity check.
3. `./install-device.sh` — confirms physical device install works.
4. Once Apple Developer Program activates:
   - Create App Store Connect record with bundle ID `studio.homefit.app`.
   - Marketing version 1.0.0, build 1 (matches `pubspec.yaml`).
   - Upload via Xcode Organizer or Transporter.
   - Subsequent uploads: bump build number (`version: 1.0.0+2`,
     `+3`, …) — TestFlight rejects duplicate build numbers within the
     same marketing version.

## Out of scope for this prep

- IAP / StoreKit (homefit.studio is not a Reader App; credits sold via
  PayFast on the web portal — no on-device purchases).
- Privacy + Terms scaffolding (separate sub-agent).
- Credits-related UI compliance (separate sub-agent).
