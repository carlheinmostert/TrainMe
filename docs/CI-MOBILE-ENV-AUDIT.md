# Mobile ENV-Awareness Audit — 2026-05-12

## Table of Contents

- [Context](#context)
- [Scope of this audit](#scope-of-this-audit)
- [Findings](#findings)
  - [F1 — OAuth deep-link scheme is bundle-ID-pinned (medium)](#f1--oauth-deep-link-scheme-is-bundle-id-pinned-medium)
  - [F2 — User-visible "manage.homefit.studio" copy in fallback strings (low)](#f2--user-visible-managehomefitstudio-copy-in-fallback-strings-low)
  - [F3 — Out-of-credits chip copy hardcodes prod portal hostname (low)](#f3--out-of-credits-chip-copy-hardcodes-prod-portal-hostname-low)
  - [F4 — Native MethodChannel names still on legacy `com.raidme.*` prefix (informational)](#f4--native-methodchannel-names-still-on-legacy-comraidme-prefix-informational)
  - [F5 — `share_kit_templates.dart` references prod URL in dartdoc only (informational, clean)](#f5--share_kit_templatesdart-references-prod-url-in-dartdoc-only-informational-clean)
  - [F6 — Supabase project refs are clean (informational, clean)](#f6--supabase-project-refs-are-clean-informational-clean)
- [Summary](#summary)

## Context

The CI/CD release-train cutover on 2026-05-11 wired `--dart-define=ENV=prod|staging|branch` into `install-device.sh` + `install-sim.sh` + `bump-version.sh`. `AppConfig.supabaseUrl` + `AppConfig.supabaseAnonKey` resolve correctly off this flag, so data routing works.

This PR (`fix/env-aware-share-urls`) fixed the 7 hardcoded URL constants that did NOT switch on `ENV`:

- `app/lib/config.dart` `webPlayerBaseUrl` (now backed by `webPlayerOrigin` getter)
- `app/lib/services/sync_service.dart` plan-URL fallback construction
- `app/lib/services/portal_links.dart` `portalOrigin` (now backed by `AppConfig.portalOrigin`)
- `app/lib/screens/home_screen.dart` (2 call sites: help icon + getting-started banner)
- `app/lib/screens/settings_screen.dart` (3 call sites: privacy, terms, referral share template)
- `app/lib/widgets/network_share_sheet.dart` referral URL builder

This document captures the **follow-up** audit Carl asked for: other config that should be ENV-aware but isn't, surfaced during the same sweep.

## Scope of this audit

A focused grep across `app/lib/**` for:

- Bundle ID / OAuth scheme constants tied to one variant of the iOS app
- Hardcoded Supabase project refs outside `config.dart`
- `if env == prod` branches with asymmetric logic
- Any other hardcoded URL / hostname tied to one deploy environment
- User-visible copy strings naming `manage.homefit.studio` or `session.homefit.studio` explicitly (these read wrong in a staging build even if no URL is constructed)

## Findings

### F1 — OAuth deep-link scheme is bundle-ID-pinned (medium)

- **File:** `app/lib/config.dart:163-164`
- **Constant:** `AppConfig.oauthRedirectUrl = 'studio.homefit.app://login-callback'`
- **Issue:** When Google / Apple Sign-In is re-enabled (currently UI-removed but SDK code wired — see `docs/BACKLOG_GOOGLE_SIGNIN.md`), this deep-link scheme is the load-bearing piece that routes the OAuth callback back into the app. Today it points at the prod bundle ID `studio.homefit.app`. If a future dev / staging build ships with a `.dev` suffix (e.g. `studio.homefit.app.dev`), OAuth will silently route to whichever app is registered for `studio.homefit.app://` — which on a phone with both installed is non-deterministic.

  Note: Carl's CLAUDE.md call-out on the 2026-04-28 bundle-ID rebrand explicitly says "Android `applicationId`, macOS, Dart `name: raidme` package, MethodChannel names, and `raidme.db` SQLite filename deliberately untouched (separate refactors)". The single bundle ID `studio.homefit.app` is current state — no `.dev` variant exists yet — so this is **latent**, not active.

- **Severity:** **Medium** — only bites when a dev / staging bundle variant is introduced (post-MVP work). MVP TestFlight uses the single bundle ID and is unaffected.
- **Recommended fix:** When dev / staging bundle variants are introduced, lift this to an env-resolved getter on the same pattern as `supabaseUrl`:
  ```dart
  static String get oauthRedirectUrl {
    final bundle = env == 'prod' ? 'studio.homefit.app' : 'studio.homefit.app.dev';
    return '$bundle://login-callback';
  }
  ```
  Pair with the Info.plist `CFBundleURLTypes` update + Supabase auth redirect allowlist update.
- **Status:** Flagged for the OAuth re-enable wave; do **not** fix in this PR (would be a no-op against current state and risks regressing the existing TestFlight flow).

### F2 — User-visible "manage.homefit.studio" copy in fallback strings (low)

- **Files:** `app/lib/screens/home_screen.dart:335`, `app/lib/screens/home_screen.dart:1369`
- **Issue:** Both are SnackBar fallback strings shown only when `launchUrl()` for the help / getting-started page fails. Hard-coded text `"Couldn't open the walkthrough. Visit manage.homefit.studio/getting-started"`. In a staging build, the user is told to visit prod when they actually want staging.

  The `launchUrl()` call itself now opens the correct env (fixed in this PR). The fallback string is the residual issue — only seen when the launch fails, which on iOS is rare (no browser → SafariViewController fallback handles it).

- **Severity:** **Low** — fallback-only path, user-visible text drift; not a functional bug. Worst case: a staging tester sees "manage.homefit.studio" and gets confused; the URL their app would otherwise open is correctly staging.
- **Recommended fix:** Interpolate the host portion of `AppConfig.portalOrigin` into the SnackBar text:
  ```dart
  content: Text(
    "Couldn't open the walkthrough. Visit "
    "${Uri.parse(AppConfig.portalOrigin).host}/getting-started",
  ),
  ```
  Drops the `const` on the SnackBar widget — acceptable trade-off for one fallback path.
- **Status:** Out of scope for this PR (would expand the diff into copy-string territory). Trivial follow-up.

### F3 — Out-of-credits chip copy hardcodes prod portal hostname (low)

- **File:** `app/lib/widgets/home_credits_chip.dart:150-151`
- **Issue:** Static `Text` widget showing `"You're out of credits. Top up at manage.homefit.studio when you're at your computer."` — bare text, no URL launch (Reader-App compliance per `feedback_ios_reader_app.md`). In a staging build, the copy still names `manage.homefit.studio`.
- **Severity:** **Low** — same shape as F2. Cosmetic / informational; no functional impact.

  Caveat: this string is **load-bearing for Apple Reader-App compliance** (no IAP path, no buy button, no tappable upsell). The exact wording was iterated on per the memory note; resist over-clever fixes that re-introduce a `launchUrl` or tappable target. The fix should keep the text plain and inert.
- **Recommended fix:** Inject the bare hostname:
  ```dart
  Text(
    "You're out of credits. Top up at "
    "${Uri.parse(AppConfig.portalOrigin).host} "
    "when you're at your computer.",
  )
  ```
  Drops the `const` on this widget; acceptable.
- **Status:** Out of scope for this PR. Trivial follow-up; bundle with F2 if/when worth a sweep.

### F4 — Native MethodChannel names still on legacy `com.raidme.*` prefix (informational)

- **Files:** `app/lib/services/conversion_service.dart`, `app/lib/screens/unified_preview_screen.dart`, `app/lib/services/unified_preview_scheme_bridge.dart`, `app/lib/screens/client_avatar_capture_screen.dart`
- **Channels:** `com.raidme.video_converter`, `com.raidme.native_thumb`, `com.raidme.unified_preview_audio`, `com.raidme.unified_preview_scheme`, `com.raidme.avatar_camera`
- **Issue:** None — this is deliberate. CLAUDE.md (PR #125 notes): "MethodChannel names ... deliberately untouched (separate refactors, not blocking TestFlight)." Renaming is a coordinated Swift + Dart rename and would touch the iOS audio mux + video pipeline; not env-related.
- **Severity:** **Informational** — not a config bug.
- **Recommended fix:** None. Re-flag during the post-MVP `raidme → homefit` rename refactor.

### F5 — `share_kit_templates.dart` references prod URL in dartdoc only (informational, clean)

- **File:** `app/lib/services/share_kit_templates.dart:28`
- **Constant:** Dartdoc example `e.g. https://manage.homefit.studio/r/K3JT7QR`.
- **Issue:** None — this is doc-comment text describing the `referralLink` slot shape. The actual `referralLink` value is passed in via `ShareKitSlots` from the call site, which now (post this PR) goes through `AppConfig.portalOrigin`.
- **Severity:** **Informational** — clean.
- **Recommended fix:** None.

### F6 — Supabase project refs are clean (informational, clean)

- **Files:** `app/lib/config.dart` only
- **Issue:** None. Grep for `yrwcofhovrcydootivjx` / `vadjvkmldtoeyspyoqbx` outside `config.dart` returned zero matches in `app/lib/**`. All project refs flow through `AppConfig.supabaseUrl`.
- **Severity:** **Informational** — clean.
- **Recommended fix:** None.

## Summary

| ID | Severity | Action |
|----|----------|--------|
| F1 — OAuth scheme bundle-ID pinning | Medium (latent) | Defer to OAuth re-enable wave |
| F2 — Home SnackBar fallback copy | Low | Trivial follow-up |
| F3 — Out-of-credits chip copy | Low | Trivial follow-up (preserve Reader-App compliance) |
| F4 — Legacy MethodChannel names | Informational | No action — deliberate |
| F5 — Dartdoc example URL | Informational | No action — clean |
| F6 — Supabase project refs | Informational | No action — clean |

**Net:** Zero active bugs outside the 7-URL scope this PR fixes. Two low-severity copy-string drifts (F2, F3) are flagged for a follow-up sweep. One medium-severity latent issue (F1) is parked behind the OAuth re-enable work.
