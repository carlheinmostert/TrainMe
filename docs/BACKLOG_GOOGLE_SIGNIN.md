# Google Sign-In: Nonce-Mismatch Post-Mortem (Post-MVP Backlog)

**Status:** Parked. MVP ships with magic-link email auth.
**Date parked:** 2026-04-18
**Parked commit on main:** `8c685f3` (next commit pivots Sign-In UI to magic-link; Google button hidden behind "coming soon" badge).

## Summary

Native Google Sign-In is blocked by a nonce-mismatch between the iOS `GoogleSignIn` SDK 8.x and Supabase's `signInWithIdToken` verifier. The native SDK injects an OpenID Connect nonce claim into the id_token; the Flutter `google_sign_in` plugin (both v6 and v7) doesn't surface the raw nonce to Dart; Supabase verifies the claim and rejects the token. Three layers, no Dart-side escape hatch.

Exact Supabase error surfaced at step 4 onward (grep this string to land here):

```
AuthApiException: Passed nonce and nonce in id_token should either both exist or not., statusCode: 400
```

## Timeline of Failures (2026-04-18, ~2h)

1. **Supabase `signInWithOAuth` + `LaunchMode.externalApplication`** — opens system Safari. iOS 17+ throws the "Open in 'homefit.studio'?" confirmation dialog before handing the custom-scheme redirect back. Dialog silently fails; deep link never reaches the app; Flutter stuck on spinner; Safari parked on `manage.homefit.studio` (Supabase Site URL fallback). Confirmed via `xcrun simctl openurl`. Commit: `db057b1`'s predecessor. **Root cause:** iOS 17+ user-consent gate for cross-app custom schemes.

2. **`LaunchMode.platformDefault` (ASWebAuthenticationSession)** — Apple's dedicated OAuth surface, shares Safari cookies, auto-follows custom schemes. Real iPhone result: blank `accounts.google.com` page. **Root cause:** Google browser-fingerprints ASWebAuthenticationSession as an isolated/insecure context and refuses to render the login UI on first use. Commit: `db057b1`.

3. **`LaunchMode.inAppBrowserView` (SFSafariViewController)** — in-app Safari with shared cookies. Theoretical Goldilocks. Same blank Google page on device. **Root cause:** Google's fingerprinting still flags SFSafariViewController. Commit: `4e4820f`.

4. **Native `google_sign_in` 7.2.0** — iOS native account picker, bypasses browsers entirely. Returns a valid `idToken`. Supabase `signInWithIdToken` rejects with the error above. **Root cause:** v7 auto-injects a nonce claim into the id_token request but doesn't expose the raw nonce to Dart. Known regression vs v6. Commit: `5aed0e0`.

5. **Downgrade to `google_sign_in` 6.2.2** — v6 shouldn't auto-nonce. Same error. **Root cause:** the auto-nonce actually originates in the underlying native `GoogleSignIn` iOS SDK (8.x pods), not the Flutter plugin. Neither v6 nor v7 exposes the raw nonce to Dart. Commit: `6c78584`.

6. **Add `serverClientId` (web) alongside `clientId` (iOS)** — matches Supabase's canonical docs example. Theory: flipping the token's audience to the web client routes through a different native flow that skips auto-nonce. Same error. **Root cause:** auto-nonce happens at the native SDK layer regardless of audience. Commit: `8c685f3`.

## Current State on main (commit `8c685f3`)

Everything up to the last verification step works:

- `app/lib/services/auth_service.dart` uses `google_sign_in` 6.2.2 with both `clientId` + `serverClientId` passed.
- `app/ios/Runner/Info.plist` has `GIDClientID` plus the reversed-client-ID entry in `CFBundleURLSchemes`.
- Supabase Google provider has both iOS and web client IDs on the authorized-clients list.

Google returns a valid id_token. Supabase rejects it at the nonce-verification step. That's the wall.

## Root-Cause Hypothesis

iOS `GoogleSignIn` 8.x includes a `nonce` claim in the id_token as part of its OpenID Connect compliance posture. The Flutter `google_sign_in` plugin (v6 and v7) treats the nonce as an internal detail and never hands the raw value to Dart. Supabase's `signInWithIdToken` is strict: if the id_token has a `nonce` claim, a matching raw nonce **must** be passed by the caller.

Three-way mismatch:

```
iOS GoogleSignIn SDK -> generates nonce, puts it in id_token
Flutter plugin       -> swallows raw nonce, only returns id_token
Supabase verifier    -> demands raw nonce when claim is present -> rejects
```

Any one of those three fixed unblocks the flow.

## Possible Fixes (Post-Launch)

**(a) Wait for upstream.** Check `google_sign_in` release notes for a nonce-exposing API. Lowest effort; non-deterministic timing.

**(b) Custom iOS native bridge. (Recommended long-term.)** Write a Swift platform-channel that wraps `GIDSignIn` directly, generates the raw nonce on our side, passes its SHA-256 hash to `GIDSignIn.sharedInstance.signIn(...)`, and returns both the raw nonce and the id_token to Dart. Pass both to Supabase `signInWithIdToken`. Estimated ~1 day. Also teaches us the OIDC flow end-to-end, which is useful for Apple Sign-In anyway.

**(c) `firebase_auth` + `signInWithCredential`.** Firebase's Google flow is known to interoperate with Supabase via id-token exchange. Overkill for our stack — pulls in a second auth provider — but battle-tested.

**(d) WKWebView OAuth.** Own the webview chrome, set a desktop-class user-agent, intercept the redirect. Sidesteps both the iOS 17+ custom-scheme dialog and Google's browser fingerprinting. Moderate cost, fragile to Google's fingerprint evolution.

**(e) Custom Supabase Edge Function.** Bypass `signInWithIdToken`. Verify the Google token ourselves (trust the source, skip the nonce check), mint a Supabase session via the admin API. Maximum flexibility, maximum blast radius if we get verification wrong.

## Recommended Next Step

Start with **(a)** — quick check on the latest `google_sign_in` release for nonce-related changes. If still absent, go straight to **(b)**. The native bridge is the most robust long-term fix and pays dividends on the Apple Sign-In implementation.

## What We Kept in Place Post-Pivot

Re-enabling this is a one-line UI change, not a config re-plumb:

- Google Cloud Console: web + iOS OAuth clients stay registered.
- Supabase Google provider: both client IDs remain on the Authorized Client IDs list.
- `app/ios/Runner/Info.plist`: `GIDClientID` + reversed-scheme `CFBundleURLSchemes` stay.
- `app/pubspec.yaml`: `google_sign_in: 6.2.2` stays as a leave-behind dependency.
- `app/lib/services/auth_service.dart`: native sign-in code stays, just gated off in the UI.

## Bundle ID rebrand follow-up (2026-04-28)

When SIWA / Google is re-enabled, the redirect plumbing now points at the
new bundle ID. Specifically:

- `AppConfig.oauthRedirectUrl` now resolves to `studio.homefit.app://login-callback`.
- iOS `Info.plist` `CFBundleURLSchemes` now contains `studio.homefit.app`.
- Supabase auth redirect allowlist needs `studio.homefit.app://` added
  (current allowlist: `https://manage.homefit.studio/**`,
  `http://localhost:3000/**`).
- Google Cloud Console iOS OAuth client: regenerate against the new bundle ID
  `studio.homefit.app` (the existing `com.raidme.raidme` iOS client will stop
  matching once the app is installed under the new ID).
- Apple Sign-In: when the Apple Developer Program activates, the Service ID +
  return URL configuration should use `studio.homefit.app://` from the start.

## Links

- Supabase Flutter Google docs: https://supabase.com/docs/guides/auth/social-login/auth-google
- `google_sign_in` Flutter package: https://pub.dev/packages/google_sign_in
- iOS `GoogleSignIn` SDK: https://github.com/google/GoogleSignIn-iOS
- Attempt history on disk: `git log app/lib/services/auth_service.dart` (commits `3c4778b` -> `db057b1` -> `4e4820f` -> `5aed0e0` -> `6c78584` -> `8c685f3`)
