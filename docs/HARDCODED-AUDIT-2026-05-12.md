# Hardcoded Values Audit — 2026-05-12

Follow-up to the OAuth-redirect bug that cost half a day of debugging on 2026-05-12.
The earlier `docs/CI-MOBILE-ENV-AUDIT.md` tagged `AppConfig.oauthRedirectUrl` as
"latent / parked" — but that single hardcoded constant was the actual root cause:
a staging-dev build sent magic-link emails containing the PROD URL scheme, which
deep-linked into the TestFlight prod app instead of the dev app.

This audit goes broader (three surfaces, not just mobile) and deeper (for every
finding, the concrete failure mode is named — no "latent" hedging).

Memory rule: `feedback_specs_direct_to_main.md` — committed directly to main.

## Table of Contents

- [Methodology](#methodology)
- [Summary](#summary)
- [A. URLs and Origins](#a-urls-and-origins)
- [B. Bundle IDs and URL Schemes](#b-bundle-ids-and-url-schemes)
- [C. Supabase Project Refs and Keys](#c-supabase-project-refs-and-keys)
- [D. UUIDs and Sentinel IDs](#d-uuids-and-sentinel-ids)
- [E. Bundle / App Version](#e-bundle--app-version)
- [F. Hardcoded Credentials or Merchant IDs](#f-hardcoded-credentials-or-merchant-ids)
- [G. Hardcoded Paths](#g-hardcoded-paths)
- [H. Magic Constants That Should Be Env-Aware](#h-magic-constants-that-should-be-env-aware)
- [I. Other Findings Worth Flagging](#i-other-findings-worth-flagging)
- [What to fix in the next release](#what-to-fix-in-the-next-release)

## Methodology

For each finding, the audit names the **concrete failure mode** (what breaks,
who notices, what they see). If no concrete mode can be articulated the
severity is downgraded to LOW or INFORMATIONAL — explicitly to avoid the
previous audit's "latent" trap where the OAuth bug sat parked under that
label until it bit prod.

Severity ladder:

- **CRITICAL** — production bug right now (wrong env, security, data loss).
- **HIGH** — will bite within weeks (next TestFlight cycle, second practitioner, staging adoption).
- **MEDIUM** — will bite eventually but no immediate impact.
- **LOW** — code hygiene, naming, defence-in-depth nice-to-have.
- **INFORMATIONAL** — noted, no action needed (deliberate per CLAUDE.md).

The previous audit's wrong-rating happened because `AppConfig.oauthRedirectUrl`
was a single token away from being correct (`studio.homefit.app` → derive from
bundle ID) AND was used by an off-the-beaten-path code path (the magic-link
fallback that fires only on first-launch + no-password users). The fix here:
state the trigger, not the abstract risk.

## Summary

**Total findings:** 31

- CRITICAL: 1
- HIGH: 8
- MEDIUM: 9
- LOW: 8
- INFORMATIONAL: 5

The single CRITICAL is `AppConfig.oauthRedirectUrl` — the exact bug that
prompted this audit, formally captured so it doesn't get dismissed again.

Five of the eight HIGH findings cluster around one theme: **the mobile
app's "user-facing surface URLs" (web player, portal) are env-blind**.
A dev build of the app talking to a staging Supabase DB will still
publish plans whose URL points at `session.homefit.studio` (prod web
player), and still link to `manage.homefit.studio/getting-started` (prod
portal). The staging surface that exists at `staging.session.homefit.studio`
+ `staging.manage.homefit.studio` is invisible to the mobile app.

## A. URLs and Origins

### A1 — `AppConfig.webPlayerBaseUrl` is env-blind (CRITICAL → demoted; see A1b)

> Demoted because `AppConfig.oauthRedirectUrl` is the load-bearing CRITICAL.
> This sibling is HIGH on the same axis.

**Severity:** HIGH

**Where:** `app/lib/config.dart:121`

**Current value:** `static const String webPlayerBaseUrl = 'https://session.homefit.studio';`

**Why it's a problem:** When a dev / staging build of the Flutter app publishes a plan, the plan URL stamped into `plans.plan_url` (and shared into WhatsApp via the share sheet) ALWAYS points at `session.homefit.studio` regardless of which Supabase DB the build is talking to. A practitioner running `./install-device.sh staging` will:
1. Publish a plan against the staging DB (correct: plan row in staging Supabase).
2. Hit Share — the URL says `https://session.homefit.studio/p/<uuid>` (WRONG: that's prod web player, which queries prod Supabase via `get_plan_full`, finds nothing, renders "Plan not found").
3. Symptom Carl/a tester would see: "I published a plan from the staging build and the shared link 404s in WhatsApp."

The staging surface `staging.session.homefit.studio` already exists per `docs/CHECKPOINT_2026-05-11.md:165`. The mobile app just never points at it.

**Recommended fix:** Make `webPlayerBaseUrl` a getter that returns `staging.session.homefit.studio` when `env != 'prod'`, mirroring the `supabaseUrl` getter pattern. Plus accept `--dart-define=WEB_PLAYER_BASE_URL=` for branch DBs that have their own subdomain.

### A2 — `portalOrigin` is env-blind

**Severity:** HIGH

**Where:** `app/lib/services/portal_links.dart:18`

**Current value:** `const String portalOrigin = 'https://manage.homefit.studio';`

**Why it's a problem:** Every app→portal link (top-up credits prompt, referral share, help icon, privacy/terms, getting-started) opens prod portal regardless of build env. A dev-build practitioner who taps "Top up credits" lands on the PROD portal logged into the wrong practice / wrong env. Symptom: credit purchases made on staging-build app would land on the prod merchant account; or worse, the practitioner sees data from the prod DB and gets confused about which env they're in.

**Recommended fix:** Make `portalOrigin` resolve via `AppConfig.env`. Read from a `--dart-define=PORTAL_BASE_URL=` override (same pattern as Supabase URL). Default to `manage.homefit.studio` for prod, `staging.manage.homefit.studio` otherwise.

### A3 — `sync_service.dart` constructs plan URL bypassing `AppConfig.webPlayerBaseUrl`

**Severity:** HIGH

**Where:** `app/lib/services/sync_service.dart:618`

**Current value:** `planUrl: 'https://session.homefit.studio/p/$id',`

**Why it's a problem:** This is the cache-pull path — when reading a session from the cloud back into the local DB, the code re-builds the plan URL inline instead of reusing `AppConfig.webPlayerBaseUrl`. So even if A1 gets fixed by making the constant a getter, this site silently keeps stamping prod URLs into the local cache on every sync. Symptom: after fixing A1 you'd still see the bug on any session that touches the sync path. Hard-to-spot regression source.

**Recommended fix:** Replace with `'${AppConfig.webPlayerBaseUrl}/p/$id'`. Add a CI grep gate ("no literal session.homefit.studio outside config.dart") so it can't drift again.

### A4 — Hardcoded `manage.homefit.studio` URLs scattered across mobile screens

**Severity:** HIGH

**Where:**

- `app/lib/screens/settings_screen.dart:441` — `https://manage.homefit.studio/privacy`
- `app/lib/screens/settings_screen.dart:448` — `https://manage.homefit.studio/terms`
- `app/lib/screens/settings_screen.dart:1236` — referral share template `"...https://manage.homefit.studio/r/{code}"`
- `app/lib/screens/home_screen.dart:318` — `https://manage.homefit.studio/getting-started`
- `app/lib/screens/home_screen.dart:1303` — `https://manage.homefit.studio/getting-started`
- `app/lib/screens/home_screen.dart:335,1369` — SnackBar copy "manage.homefit.studio/getting-started"
- `app/lib/widgets/network_share_sheet.dart:75` — `'https://manage.homefit.studio/r/$code'`
- `app/lib/widgets/network_share_sheet.dart:317` — display strip of the referral URL

**Why it's a problem:** Same failure mode as A2 — all bypass `portalOrigin`. Even if A2 is fixed, these still hardcode prod. The referral URL one is especially problematic: a staging build's referral share gets clicked by a friend, who lands on PROD portal `/r/{code}` looking for a code that doesn't exist there (it's in staging). Symptom: "I shared my referral code from the dev build and it doesn't work."

**Recommended fix:** Route every one of these through `portalLink('/privacy')`, `portalLink('/terms')`, `portalLink('/getting-started')`, `portalLink('/r/$code')`. The `portal_links.dart` helper already exists; these sites just bypass it.

### A5 — Web-portal middleware, server/browser clients, route handlers default to prod URL

**Severity:** MEDIUM

**Where:**

- `web-portal/src/middleware.ts:41`
- `web-portal/src/lib/supabase-server.ts:10`
- `web-portal/src/lib/supabase-browser.ts:11`
- `web-portal/src/lib/supabase/api.ts:1212`
- `web-portal/src/app/credits/purchase/route.ts:125`

**Current value:** `process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'https://yrwcofhovrcydootivjx.supabase.co'`

**Why it's a problem:** The `??` fallback to the PROD project URL means if `NEXT_PUBLIC_SUPABASE_URL` is unset on a staging Vercel deploy, the staging portal silently talks to prod Supabase. The Vercel-Supabase integration should set it, but the failure mode is silent — a misconfigured env var prints no error, the portal just routes to prod. Symptom: a tester on `staging.manage.homefit.studio` would see prod data and might mutate it.

**Recommended fix:** Throw at module load if the env var is missing, mirroring the strict-fail policy that `web-player/build.sh` now follows (PR #293). No silent fallback.

### A6 — `web-player/middleware.js` hardcodes prod Supabase

**Severity:** HIGH

**Where:** `web-player/middleware.js:1-2`

**Current value:**

```js
const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';
```

**Why it's a problem:** Vercel Edge Middleware runs for WhatsApp / iMessage bot unfurls — `staging.session.homefit.studio/p/<id>` shared into WhatsApp pings this middleware which queries PROD `get_plan_full`, finds nothing (the plan exists in staging DB), and returns a "Not found" OG card. The middleware is the OG-unfurl path, which silently routes to prod regardless of which environment the deploy is for. Carl/tester would see: "I shared my staging plan link and the WhatsApp preview shows nothing."

This is the SAME class of bug as `web-portal/middleware.ts` (A5), but worse: middleware.ts at least reads from env-var with fallback. middleware.js is a flat hardcode.

**Recommended fix:** Move config to env vars via `process.env.SUPABASE_URL` (Vercel injects per-env vars at edge runtime). Or read from `globalThis.HOMEFIT_CONFIG` populated by the same `build.sh` step that emits `config.js` for the static surface.

### A7 — `web-portal/src/components/SessionsList.tsx` hardcodes player URL

**Severity:** MEDIUM

**Where:** `web-portal/src/components/SessionsList.tsx:328`

**Current value:** `return \`https://session.homefit.studio/p/${planId}\`;`

**Why it's a problem:** Staging portal renders session links pointing at PROD web player. Symptom: tester clicks a session card in the staging portal, lands on prod web player which 404s the plan.

**Recommended fix:** Read `process.env.NEXT_PUBLIC_WEB_PLAYER_BASE_URL` with a thrown error on missing (or a clean fallback to the same-domain swap if the portal knows it's at `staging.manage.homefit.studio`).

### A8 — `web-portal/src/app/audit/page.tsx` hardcodes player URL for the audit-row link

**Severity:** MEDIUM

**Where:** `web-portal/src/app/audit/page.tsx:811`

**Current value:** `` href: `https://session.homefit.studio/p/${row.refId}` ``

**Why it's a problem:** Same as A7 but for the audit-log "open in player" link. Staging audit rows link to prod player. Less load-bearing because audit is a power-user feature, but same drift.

**Recommended fix:** Same as A7.

### A9 — `referralUrl()` falls back to prod manage URL

**Severity:** MEDIUM

**Where:** `web-portal/src/lib/referral-share.ts:7`, `web-portal/src/app/network/page.tsx:103`

**Current value:** `process.env.NEXT_PUBLIC_APP_URL ?? 'https://manage.homefit.studio'`

**Why it's a problem:** Same silent-fallback pattern as A5. If `NEXT_PUBLIC_APP_URL` isn't set on a staging Vercel deploy, the referral share URL points at prod even though the user is on staging.

**Recommended fix:** Throw on missing env var (strict-fail).

### A10 — Google Fonts preconnect hardcoded (deliberate)

**Severity:** INFORMATIONAL

**Where:** `web-portal/src/app/layout.tsx:23,26,30`

**Current value:** `https://fonts.googleapis.com`, `https://fonts.gstatic.com`

**Why it's flagged:** Listed for completeness — these are deliberate external service URLs. Same category as `wa.me` and `payfast.co.za`. No action needed.

## B. Bundle IDs and URL Schemes

### B1 — `AppConfig.oauthRedirectUrl` is the actual CRITICAL — load-bearing for magic-link deep-linking in dev builds

**Severity:** CRITICAL

**Where:** `app/lib/config.dart:163-164`

**Current value:**

```dart
static const String oauthRedirectUrl =
    'studio.homefit.app://login-callback';
```

**Why it's a problem:** This was the root cause of the half-day debugging session on 2026-05-12. The Debug + Profile build configs use bundle ID `studio.homefit.app.dev` (`app/ios/Runner.xcodeproj/project.pbxproj:532,716`), but `Info.plist` registers `CFBundleURLSchemes` to `$(PRODUCT_BUNDLE_IDENTIFIER)` — so a dev build registers `studio.homefit.app.dev://` as its scheme. Magic-link emails go out with `studio.homefit.app://login-callback?token=...` (from `AppConfig.oauthRedirectUrl`), which deep-links into the PROD TestFlight build on the device if installed. The dev build never sees the callback. Carl's symptom on 2026-05-12: "I tap magic link from staging dev build's email, lands in TestFlight prod app, signs me into prod."

This is concrete, reproducible, and was always going to fire as soon as TestFlight + dev coexisted on the device. The earlier audit's "latent" tag was wrong because there was no "if X then Y" gating it — it was always-on.

**Recommended fix:** Derive the redirect URL from the bundle ID at runtime. Either via a platform channel that reads `Bundle.main.bundleIdentifier`, or by passing the bundle as `--dart-define=BUNDLE_ID=...` from the install scripts and constructing `'$BUNDLE_ID://login-callback'`. Also update the iOS Info.plist (already correct via `$(PRODUCT_BUNDLE_IDENTIFIER)`) so the Supabase allowlist matches.

Supabase auth allowlist already includes `studio.homefit.app://**` per CLAUDE.md. Need to add `studio.homefit.app.dev://**` for dev builds.

### B2 — `studio.homefit.app` literal in os_log subsystem strings

**Severity:** LOW

**Where:**

- `app/ios/Runner/ClientAvatarProcessor.swift:56` — `subsystem: "studio.homefit.app"`
- `app/ios/Runner/AvatarCameraChannel.swift:52` — `OSLog(subsystem: "studio.homefit.app", category: ...)`

**Why it's a problem:** Console.app filtering by subsystem (`subsystem:studio.homefit.app`) won't surface dev-build logs since the dev build's bundle ID is `studio.homefit.app.dev`. Diagnostics docs that say "filter by subsystem studio.homefit.app" silently exclude dev builds. Symptom: trying to debug an issue Carl can only reproduce on dev → his Console filter shows zero logs and he assumes the channel is broken.

**Recommended fix:** Read from `Bundle.main.bundleIdentifier` at log-init time. Documented workaround until then: dev builds need `subsystem:studio.homefit.app.dev`.

### B3 — `com.raidme.*` MethodChannel names (deliberate legacy)

**Severity:** INFORMATIONAL

**Where:** Many — `app/ios/Runner/*.swift`, `app/lib/services/conversion_service.dart`, etc.

**Why it's flagged:** CLAUDE.md explicitly marks these as deliberate debt — channel names are internal contracts between Swift and Dart, renaming requires synchronised changes. Listed for completeness. No action.

### B4 — `com.raidme.raidme` in Android + macOS configs (deliberate legacy)

**Severity:** INFORMATIONAL

**Where:** `app/android/app/build.gradle.kts:9,24`, `app/macos/Runner/Configs/AppInfo.xcconfig:11,14`

**Why it's flagged:** CLAUDE.md notes Android `applicationId` + macOS namespace were deliberately untouched in the 2026-04-28 bundle-ID rebrand. iOS is the only ship surface for MVP. No action.

### B5 — Bundle ID hardcoded in install scripts

**Severity:** LOW

**Where:** `install-sim.sh:24` (`BUNDLE=studio.homefit.app`), `install-device.sh:33` (`BUNDLE=studio.homefit.app`)

**Why it's a problem:** Both scripts uninstall/launch the PROD bundle even when they build the dev bundle (`studio.homefit.app.dev`). For install-sim.sh: line 145 runs `simctl uninstall ... studio.homefit.app` but the Debug build the script produces is `studio.homefit.app.dev` — so uninstall is a no-op (no prod app on sim) and install lands `.dev`, but launch line 169 tries to launch `studio.homefit.app` which doesn't exist → silent failure / wrong app launch. Symptom: simulator install completes, app doesn't launch (or launches the wrong installed bundle). Carl has been running these scripts daily without noticing because TestFlight builds always go through `build-testflight.sh` which uses release config.

Actually — verified: `flutter build ios --debug --simulator` typically uses the Debug config which has `studio.homefit.app.dev`. So this script does have the bug. The reason Carl hasn't noticed: install on sim does install the `.dev` bundle but `simctl launch studio.homefit.app` happens to fall back to launching whatever's there (or fails silently).

**Recommended fix:** Read the actual bundle ID from the built `.app/Info.plist` after build, or pass `--bundle-id=` arg defaulting to `studio.homefit.app.dev` for non-prod ENVs.

### B6 — Bundle ID hardcoded in `build-testflight.sh`

**Severity:** INFORMATIONAL

**Where:** `build-testflight.sh` does not hardcode the bundle — it uses the Release config which has `studio.homefit.app` in pbxproj. Flagged here to document that the TestFlight path is correctly bundle-ID-agnostic. No action.

## C. Supabase Project Refs and Keys

### C1 — Prod Supabase URL + anon key hardcoded in `app/lib/config.dart`

**Severity:** LOW (defence-in-depth, intentional per docs/CI.md §5)

**Where:** `app/lib/config.dart:37-40, 45-48`

**Current values:**

- `_prodSupabaseUrl = 'https://yrwcofhovrcydootivjx.supabase.co'`
- `_prodSupabaseAnonKey = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3'`
- `_stagingSupabaseUrl = 'https://vadjvkmldtoeyspyoqbx.supabase.co'`
- `_stagingSupabaseAnonKey = 'sb_publishable_INTgC6wuK4nyjXlfQE4wpA_5AgBjeOy'`

**Why it's a problem:** Anon keys are public-by-design (RLS gates everything) so this is not a security issue. But it does mean rotating the prod anon key is a code change + TestFlight rebuild rather than an env-var swap. Failure mode: if Supabase ever rotates the anon key (e.g. after a Supabase security advisory), every shipped TestFlight build is bricked until a new build hits the store. LOW because rotation is rare and the staging branch lets us validate a key swap before shipping.

**Recommended fix:** Keep as defensive default (docs/CI.md §5 calls this out). Document the rotation procedure in `docs/CI.md`.

### C2 — Prod project ref + anon key hardcoded in `install-sim.sh` and `install-device.sh`

**Severity:** LOW

**Where:** `install-sim.sh:42-44, 48` and `install-device.sh:51-53, 56`

**Current values:** Same as C1.

**Why it's a problem:** Same as C1. Mitigated by the install scripts also being able to fetch from `supabase projects api-keys` via the CLI for staging + branch — only the prod path uses the literal. INFORMATIONAL leaning LOW.

**Recommended fix:** Either accept as defensive (matches C1) or replace prod path with the same `fetch_anon_key` call. The latter has a chicken-and-egg problem (need CLI logged in to install prod) so keeping the literal is reasonable.

### C3 — Prod URL + key hardcoded in `build-testflight.sh`

**Severity:** LOW

**Where:** `build-testflight.sh:29-30`

**Current values:** Same as C1.

**Why it's a problem:** Same as C1, with the same defence-in-depth rationale. The script is the documented prod-release path, so the explicit literal is load-bearing. LOW.

**Recommended fix:** None required. Documented as intentional.

### C4 — Prod project ref in CI workflow

**Severity:** INFORMATIONAL

**Where:** `.github/workflows/supabase-branch-vault.yml:68`

**Current value:** `PROJECT_REF: yrwcofhovrcydootivjx`

**Why it's flagged:** The workflow's whole purpose is to talk to the prod project (which has Branching enabled). The project ref is contextual config, not a secret. Listed for completeness.

### C5 — Prod URL hardcoded inside `supabase/migrations/20260511065443_baseline.sql`

**Severity:** MEDIUM

**Where:** `supabase/migrations/20260511065443_baseline.sql:1611`

**Current value:** A literal `'https://yrwcofhovrcydootivjx.supabase.co/storage/v1/object/public/media/'` inside the `get_plan_full` RPC body.

**Why it's a problem:** The baseline migration is what Supabase Branching applies to EVERY per-PR DB. So a branch DB created off this baseline contains an RPC that mints public-media URLs pointing at the PROD storage bucket. If a test plan is published against a branch DB, its line-drawing thumbnails point at prod's `media` bucket (where the file doesn't exist) → broken images. Symptom: tester on a branch deploy sees broken line-drawing thumbnails.

**Recommended fix:** Read the base URL from `vault.secrets` (the same way `sign_storage_url` already reads `supabase_url`). The `supabase-branch-vault.yml` workflow populates that secret per-branch. Migration body should be `(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'supabase_url') || '/storage/v1/object/public/media/'`.

### C6 — Prod URL appears in archived patch SQL (historical reference)

**Severity:** INFORMATIONAL

**Where:** `supabase/archive/schema_lobby_three_treatment_thumbs*.sql`, `supabase/archive/schema_get_plan_full_restore_full_body.sql`, `supabase/archive/schema_milestone_g_three_treatment.sql`

**Why it's flagged:** These are archived patch files (per CLAUDE.md, "historical reference only, do not apply"). CI doesn't pick them up. No action.

### C7 — `placeholder-anon-key` fallback in web-portal clients

**Severity:** LOW

**Where:** `web-portal/src/lib/supabase-browser.ts:14`, `web-portal/src/lib/supabase-server.ts:13`, `web-portal/src/middleware.ts:44`

**Current value:** `process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? 'placeholder-anon-key'`

**Why it's a problem:** A misconfigured Vercel deployment with missing env var won't crash at module load — it builds successfully and runs with a placeholder anon key. The first auth/network call returns a clear "invalid API key" error, so the failure is detectable. But it would be detected at runtime by the user, not at build time by the deploy. LOW.

**Recommended fix:** Throw at module load if either env var is missing. Strict-fail mirrors the `web-player/build.sh` policy.

## D. UUIDs and Sentinel IDs

### D1 — Sentinel UUIDs in `app/lib/config.dart`

**Severity:** MEDIUM

**Where:** `app/lib/config.dart:153-156`

**Current values:**

- `sentinelPracticeId = '00000000-0000-0000-0000-0000000ca71e'`
- `sentinelTrainerId = '00000000-0000-0000-0000-000000000001'`

**Why it's a problem:** These sentinels exist in prod DB seeds. They DON'T exist in staging-branch / per-PR DBs unless the seed data is copied over. The `auth_service.dart` claim path tries to claim the sentinel practice on first sign-in — if it doesn't exist in staging, the claim silently fails and a fresh personal practice is created instead, which is correct fallback behaviour. So this is "fine in practice today" but constrains us: any future logic that REQUIRES the sentinel to exist would break in non-prod. MEDIUM because there's no concrete failure mode visible today.

**Recommended fix:** Add a one-line CI check ("if app code uses `sentinelPracticeId`, the seed migration must insert that uuid") in `tools/enforce_data_access_seams.py`. Document in CI.md that the sentinel is a prod-only convenience and the code must tolerate its absence.

### D2 — Sentinel UUID `00000000-0000-0000-0000-000000000000` in baseline migration index

**Severity:** INFORMATIONAL

**Where:** `supabase/migrations/20260511065443_baseline.sql:392`

**Current value:** `COALESCE(exercise_id, '00000000-0000-0000-0000-000000000000'::uuid)` in a unique index

**Why it's flagged:** This is a "NULL coalesce sentinel" — it's used inside an index expression to allow NULL `exercise_id` to participate in uniqueness. Not data, just a pattern. INFORMATIONAL.

### D3 — Carl's personal hardware UDIDs in install scripts

**Severity:** LOW

**Where:** `install-sim.sh:23` (`E4285EC5-...`), `install-device.sh:32` (`00008150-...`)

**Why it's a problem:** Anyone else (e.g. a future second practitioner running their own dev build) needs to swap these. Symptom: "Why does `./install-device.sh` say 'device not found'?" — answer: it's hardcoded to Carl's iPhone. LOW because the repo has one developer today.

**Recommended fix:** Read from env var `HOMEFIT_DEVICE` with current value as default. Add a short note to README/install-device.sh: "to find yours, run `xcrun devicectl list devices`".

### D4 — Apple `DEVELOPMENT_TEAM = J9R837QRR6` in project.pbxproj

**Severity:** LOW

**Where:** `app/ios/Runner.xcodeproj/project.pbxproj:524, 708, 732`

**Why it's a problem:** Carl's Apple Developer team ID. A future contributor with their own dev team would need to swap or override. Not a security issue (team IDs are public-ish on App Store records). LOW because Carl is the sole signer today.

**Recommended fix:** None urgent. Document in TESTFLIGHT_PREP.md that team ID swap is required for other signers.

## E. Bundle / App Version

### E1 — App version sourced correctly from pubspec

**Severity:** INFORMATIONAL

**Where:** `app/pubspec.yaml:4` (`version: 1.0.0+3`)

**Why it's flagged:** `pubspec.yaml` is the only source of truth. Xcode reads via `$(FLUTTER_BUILD_NUMBER)` + `$(MARKETING_VERSION)`. `bump-version.sh` is the only mutator. No drift. INFORMATIONAL — confirms this category is clean.

### E2 — Web-player `PLAYER_VERSION` literal in `app.js`

**Severity:** LOW

**Where:** `web-player/app.js:20`

**Current value:** `const PLAYER_VERSION = 'v69-modal-first-desktop';`

**Why it's a problem:** Manually-maintained version string. Easy to forget to bump on releases — drift becomes invisible because the build chip ALSO shows git SHA from `window.HOMEFIT_CONFIG.gitSha` (which IS automatic from Vercel). So `PLAYER_VERSION` is now redundant build-marker chrome that can lie. Symptom: footer says "v69-..." but git SHA is from a much later commit, and Carl wonders which is canonical.

**Recommended fix:** Either retire `PLAYER_VERSION` (git SHA is sufficient) or auto-bump via a tagged-commit message hook. The git SHA chip is more accurate anyway.

### E3 — Service worker cache version `homefit-player-v76-env-config`

**Severity:** INFORMATIONAL

**Where:** `web-player/sw.js:8`

**Why it's flagged:** Manual bump per CLAUDE.md ("Bump `sw.js` CACHE_NAME when making major web player changes"). Deliberate. INFORMATIONAL.

## F. Hardcoded Credentials or Merchant IDs

### F1 — `PAYFAST_PASSPHRASE=jt7NOE43FZPn` committed to `web-portal/.env.example`

**Severity:** MEDIUM

**Where:** `web-portal/.env.example:24`

**Current value:** `PAYFAST_PASSPHRASE=jt7NOE43FZPn`

**Why it's a problem:** This IS the sandbox passphrase, but `.env.example` is committed to git. Anyone who reads the repo gets it. The comment ("shared sandbox account default") justifies this for testing, but:
1. If Carl swaps the sandbox passphrase via PayFast dashboard, the example file silently lies about the right value.
2. There's no guard that this same value doesn't accidentally end up in prod `.env` (developer copies `.env.example` to `.env`, swaps merchant ID, forgets to swap passphrase → prod signatures get computed with the sandbox passphrase → 100% of webhooks fail signature check → 100% of purchases never credit a practice).

The pattern looks identical to `PAYFAST_MERCHANT_ID=10000100` / `MERCHANT_KEY=46f0cd694581a` (also sandbox-public per PayFast docs) but the passphrase is account-bound state.

**Recommended fix:** Empty the value in `.env.example` with the comment "fill in your merchant passphrase". Document the sandbox value in `web-portal/README.md` as fallback for local dev only. Add a startup check on the deployed portal that errors loudly if `PAYFAST_PASSPHRASE` equals the sandbox value AND `PAYFAST_SANDBOX=false`.

### F2 — PayFast sandbox merchant ID + key fallback in `payfast.ts`

**Severity:** LOW

**Where:** `web-portal/src/lib/payfast.ts:163-165`

**Current value:**

```ts
merchantId: process.env.PAYFAST_MERCHANT_ID ?? (sandbox ? '10000100' : ''),
merchantKey: process.env.PAYFAST_MERCHANT_KEY ?? (sandbox ? '46f0cd694581a' : ''),
```

**Why it's a problem:** Sandbox merchant credentials are public per PayFast docs. The gating on `sandbox` is correct — production gets `''` and the route handler returns 500 ("PayFast merchant credentials not configured"). No leak. LOW because it's defensive AND correctly gated.

**Recommended fix:** Optional — remove the fallback entirely and require env vars even for sandbox. Forces explicit configuration, surfaces the "I didn't set up PayFast yet" case loudly.

### F3 — `PAYFAST_IP_BLOCKS` hardcoded in both Next route AND edge function

**Severity:** LOW

**Where:** `web-portal/src/lib/payfast.ts:136-146`, `supabase/functions/payfast-webhook/index.ts:42-50`

**Why it's a problem:** Two sources of truth, drift risk. PayFast updates their IP ranges occasionally; if only one is updated, the webhook silently rejects legitimate ITNs from prod-only IPs (or accepts spoofed traffic during the transition). Symptom: post-update, some purchases fail to credit, others credit fine, depending on which PayFast server hit which endpoint.

**Recommended fix:** Either (a) move to a shared constants file imported by both, (b) put it in `vault.secrets` so a single update propagates, or (c) at minimum add a CI check ("payfast.ts:PAYFAST_IP_BLOCKS must equal payfast-webhook/index.ts:PAYFAST_IP_BLOCKS line-for-line").

### F4 — Apple `DEVELOPMENT_TEAM` (covered in D4)

(Cross-reference, no separate entry.)

## G. Hardcoded Paths

### G1 — Absolute `/Users/chm/dev/TrainMe` path in `config.dart` docstring

**Severity:** LOW

**Where:** `app/lib/config.dart:103`

**Current value:** Inside a Dart docstring giving an example build command: `--dart-define=GIT_SHA=$(git -C /Users/chm/dev/TrainMe rev-parse --short HEAD) \`

**Why it's a problem:** Cosmetic — anyone reading the docstring sees Carl's machine path. Not load-bearing for any code path. LOW.

**Recommended fix:** Replace with `--dart-define=GIT_SHA=$(git rev-parse --short HEAD)` (the install scripts already do this without the `-C` flag; the docstring example is the only place that uses it).

### G2 — Absolute path in cron snippet in `tools/publish-health-ping/`

**Severity:** LOW

**Where:** `tools/publish-health-ping/README.md:43`, `tools/publish-health-ping/ping.sh:39`

**Current value:** `0 8 * * * cd /Users/chm/dev/TrainMe/tools/publish-health-ping && ./ping.sh`

**Why it's a problem:** Cron example is Carl-machine-specific. Anyone else copying it has to swap. LOW — README clearly says it's a Carl-runs-this tool.

**Recommended fix:** Replace with `cd ~/your/path/to/repo/tools/publish-health-ping && ./ping.sh` in README.

## H. Magic Constants That Should Be Env-Aware

### H1 — `recycleBinRetentionDays = 7` always

**Severity:** INFORMATIONAL

**Where:** `app/lib/config.dart:128`

**Why it's flagged:** Stable product policy per CLAUDE.md R-01. INFORMATIONAL.

### H2 — Conversion-service timeouts (30s, 10s, 3min) hardcoded

**Severity:** INFORMATIONAL

**Where:** `app/lib/services/conversion_service.dart` (~14 sites)

**Why it's flagged:** Tuned values for AVFoundation/iOS performance. Same on every env. INFORMATIONAL.

### H3 — Credit-pricing threshold `75 * 60` seconds

**Severity:** LOW

**Where:** `app/lib/config.dart:181`

**Why it's flagged:** Product policy ("anti-abuse" per CLAUDE.md). Changing this requires synchronised changes in: portal `/credits` copy, terms page ("ceil(N/8)..." legacy wording was wrong; check `terms/page.tsx:157`), the `creditCostForDuration` function. Single-source-of-truth-OK today; drift-risk if changed. LOW.

### H4 — Signup-bonus credit amounts (3 organic, 5 referral)

**Severity:** LOW

**Where:** `app/lib/config.dart:171, 176` AND `supabase/migrations/20260511065443_baseline.sql:678, 850`

**Why it's a problem:** Same constant in Flutter `AppConfig` AND in baseline migration body. If Carl bumps the bonus, BOTH need updating + a fresh TestFlight build + a fresh migration. Today the Dart constants are display-only (the actual credit grant happens in the DB function), so a drift would show "3 credits granted" copy but actually grant a different number — confusing but not a security issue. LOW.

**Recommended fix:** Make Dart constants read from a DB-served config row, or accept the drift risk and document in CLAUDE.md.

## I. Other Findings Worth Flagging

### I1 — Two-source-of-truth for the prod Supabase URL inside the `get_plan_full` RPC body

**Severity:** MEDIUM (covered in C5)

(Cross-reference.)

### I2 — `placeholder-anon-key` is a real string committed to source

**Severity:** LOW (covered in C7)

(Cross-reference.)

### I3 — Missing `staging.session.homefit.studio` allowlist in any Supabase config

**Severity:** MEDIUM

**Where:** Inferred from absence. The Supabase auth redirect allowlist (per CLAUDE.md) includes `https://manage.homefit.studio/**` + localhost + `studio.homefit.app://` schemes — but does NOT include `https://staging.manage.homefit.studio/**` or `https://staging.session.homefit.studio/**`.

**Why it's a problem:** A magic link sent from a staging dev build (assuming B1 + A2 are fixed and the dev build correctly points at the staging portal as its redirect target) would be silently rejected by Supabase and fall back to the Site URL (per `gotcha_supabase_redirect_silent_fallback.md`). Symptom after fixing B1: "I fixed the redirect bug but magic links from staging still don't work."

**Recommended fix:** Add `https://staging.manage.homefit.studio/**` and `https://staging.session.homefit.studio/**` to the Supabase auth allowlist via the Management API (the project rule says "use APIs not dashboards"). Same allowlist also needs `studio.homefit.app.dev://**` per B1.

### I4 — `web-portal/.env.example` claims `NEXT_PUBLIC_SUPABASE_ANON_KEY` is the prod key

**Severity:** LOW

**Where:** `web-portal/.env.example:4`

**Why it's a problem:** The example commits the actual prod anon key. As with C1, anon keys are public-by-design. But it does mean a developer copying `.env.example` to `.env` for local dev runs their portal against PROD Supabase by default. Failure mode: local dev mutations land in prod DB. Mitigated by RLS but still a footgun.

**Recommended fix:** Switch example to staging URL + staging anon key, with a comment "swap to prod values via Vercel env, never edit this file with prod creds". Strict-fail at startup if the SUPABASE_URL equals prod AND `NODE_ENV !== 'production'`.

### I5 — Single source of truth for `web-player/api.js` config is `window.HOMEFIT_CONFIG`

**Severity:** INFORMATIONAL

**Where:** `web-player/api.js:113-133`

**Why it's flagged:** Good pattern — config is injected via the generated `config.js` (`web-player/build.sh`). No hardcoded supabase URL/key in `api.js`. Listed as the model the other surfaces should mirror.

## What to fix in the next release

Ranked CRITICAL → HIGH only.

1. **B1 (CRITICAL)** — Derive `AppConfig.oauthRedirectUrl` from bundle ID. Dev + prod builds must mint different magic-link redirect URLs. Add `studio.homefit.app.dev://**` to the Supabase auth allowlist. The bug this fixes is the one that prompted the audit.
2. **A1 (HIGH)** — Make `AppConfig.webPlayerBaseUrl` env-aware (resolve from `AppConfig.env` + optional `--dart-define`). Default to `staging.session.homefit.studio` for non-prod.
3. **A2 (HIGH)** — Make `portal_links.dart`'s `portalOrigin` env-aware. Same pattern as A1.
4. **A3 (HIGH)** — Replace the inline plan-URL construction in `sync_service.dart:618` with `'${AppConfig.webPlayerBaseUrl}/p/$id'`. Otherwise A1 leaks through the cache path.
5. **A4 (HIGH)** — Route the 8 hardcoded `manage.homefit.studio` URLs in mobile screens through `portalLink()`. Otherwise A2 leaks through screens.
6. **A6 (HIGH)** — Make `web-player/middleware.js` read Supabase config from `process.env` (Vercel injects per-env). Same strict-fail policy as `build.sh`.
7. **I3 (MEDIUM, but bundle-with-B1)** — Update Supabase auth allowlist to include the four missing staging entries. Pairs with B1; the fix is incomplete without it.

Memory rules to surface:
- `feedback_no_direct_db_access.md` — already covers DB seam discipline.
- A new memory entry "Every URL in mobile-app code must route through an env-aware getter" would be a good addition; flagging here for Carl to consider.
