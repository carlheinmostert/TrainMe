# Hardcoded Values Audit — 2026-05-12 (staging-corrected)

Audited against staging tip `a62d8f01ab4907161ae3bdf5a09fbe4b1416e48a` on 2026-05-12.
Findings already addressed by PR #304 (now on staging) are explicitly marked as
RESOLVED with reference to the fix commit.

The earlier pass (commit `dcb217b` on main, doc same filename) ran off main
and missed that PR #304 already shipped to staging the env-aware getters for
`webPlayerOrigin`, `portalOrigin`, and `oauthRedirectUrl`. This re-audit
corrects that and adds findings on the partial-fix surface (string-literal
copy that wasn't migrated through the new getters).

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

Same as the main-based audit. For every finding the audit names the
**concrete failure mode** (what breaks, who notices, what they see).

Severity ladder:

- **CRITICAL** — production bug right now (wrong env, security, data loss).
- **HIGH** — will bite within weeks (next TestFlight cycle, second practitioner, staging adoption).
- **MEDIUM** — will bite eventually but no immediate impact.
- **LOW** — code hygiene, naming, defence-in-depth nice-to-have.
- **INFORMATIONAL** — noted, no action needed (deliberate per CLAUDE.md).

Findings carry one of three lifecycles:

- **RESOLVED** — addressed on staging (PR #304 or similar). One-line entry only.
- **PERSISTS** — was in the previous audit and is still present on staging.
- **NEW** — discovered in this re-audit (mostly partial-fix leakage from PR #304).

## Summary

**Total findings on staging tip:** 28 (after dedup vs previous audit's 31).

- CRITICAL: 0  (down from 1; B1 RESOLVED)
- HIGH: 6      (down from 8; A1/A2/A3 RESOLVED, partial A4 leakage stays HIGH, A6 stays HIGH)
- MEDIUM: 9
- LOW: 9
- INFORMATIONAL: 4

**5 findings RESOLVED by PR #304:** A1, A2, A3, A4 (URL-construction sites only),
B1. The earlier critical (`oauthRedirectUrl` magic-link bug) is gone.

**The shape of the remaining problem:** PR #304 routed every URL CONSTRUCTION
site through `AppConfig.webPlayerOrigin` / `AppConfig.portalOrigin` (correct),
but the **user-facing SnackBar / Text copy** that displays the URL as a
string still says "manage.homefit.studio" verbatim. So in staging, the user
sees "Visit manage.homefit.studio/getting-started" even though the actual
tap-to-open URL resolves to `staging.manage.homefit.studio/getting-started`.
Confusing for testers — also a UX leak that says "we're on prod" when the
build is staging. Three NEW findings (A11, A12, A13) cover this.

Carry-over critical class issue: `web-player/middleware.js` is STILL flat-
hardcoded to prod Supabase URL/key AND embeds the prod plan-URL into OG
cards (lines 1, 2, 62). Same failure mode as before — staging deploys'
WhatsApp unfurls 404. This is the highest-severity unresolved item.

## A. URLs and Origins

### A1 — `AppConfig.webPlayerBaseUrl` env-blind

RESOLVED in PR #304 commit `ebd9d44` (and re-affirmed on `a62d8f0`).
`AppConfig.webPlayerOrigin` getter now resolves from `env`; the old
`webPlayerBaseUrl` is now an alias getter pointing at the same value.

### A2 — `portalOrigin` env-blind

RESOLVED in PR #304 commit `ebd9d44`. `portal_links.dart:25` now reads
from `AppConfig.portalOrigin` which is env-aware.

### A3 — `sync_service.dart:618` constructs hardcoded plan URL

RESOLVED in PR #304 commit `ebd9d44`. The line is now
`planUrl: '${AppConfig.webPlayerOrigin}/p/$id',` at `sync_service.dart:619`.

### A4 (URL construction sites) — Hardcoded `manage.homefit.studio` URLs in screens

RESOLVED in PR #304 commit `ebd9d44`. Every URL-CONSTRUCTION site listed
in the previous audit now reads from `AppConfig.portalOrigin`:
- `settings_screen.dart:441` (`/privacy`) ✓
- `settings_screen.dart:448` (`/terms`) ✓
- `settings_screen.dart:1239` (referral share template) ✓
- `home_screen.dart:319` (getting-started, primary tap) ✓
- `home_screen.dart:1355` (getting-started, banner tap) ✓
- `network_share_sheet.dart:76` (referral URL) ✓

The **display-string** instances (SnackBar copy, credit chip copy) are
NEW findings A11, A12, A13 — see below.

### A5 — Web-portal middleware, server/browser clients, route handlers default to prod URL

**Severity:** MEDIUM (PERSISTS)

**Where:**

- `web-portal/src/middleware.ts:41`
- `web-portal/src/lib/supabase-server.ts:10`
- `web-portal/src/lib/supabase-browser.ts:11`
- `web-portal/src/lib/supabase/api.ts:1212`
- `web-portal/src/app/credits/purchase/route.ts:125`

**Current value:** `process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'https://yrwcofhovrcydootivjx.supabase.co'`

**Why it's a problem:** The `??` fallback to the prod project URL means
if `NEXT_PUBLIC_SUPABASE_URL` is unset on a staging Vercel deploy, the
staging portal silently talks to prod Supabase. Symptom: a tester on
`staging.manage.homefit.studio` would see prod data and might mutate it.

**Recommended fix:** Throw at module load if the env var is missing.
Mirror the strict-fail policy that `web-player/build.sh` follows (PR #293).

### A6 — `web-player/middleware.js` hardcodes prod Supabase

**Severity:** HIGH (PERSISTS — highest unresolved item)

**Where:** `web-player/middleware.js:1-2`

**Current value:**

```js
const SUPABASE_URL = 'https://yrwcofhovrcydootivjx.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3';
```

**Why it's a problem:** Vercel Edge Middleware runs for WhatsApp /
iMessage bot unfurls. A staging deploy of the web player at
`staging.session.homefit.studio/p/<id>` shared into WhatsApp hits THIS
middleware which queries PROD `get_plan_full`, finds nothing (plan
lives in staging DB), and returns "Plan not found" OG card.
This is the OG-unfurl path; staging deploys' shared links unfurl as 404s.

This finding is the most concrete pre-prod-tester blocker on the list.

**Recommended fix:** Read Supabase config from `process.env` at edge
runtime (Vercel injects per-env). Add the same strict-fail guard as
`build.sh`.

### A6b — `web-player/middleware.js` embeds prod plan URL into OG card

**Severity:** HIGH (NEW)

**Where:** `web-player/middleware.js:62`

**Current value:** `` const planUrl = `https://session.homefit.studio/p/${planId}`; ``

**Why it's a problem:** Even if A6 is fixed (middleware reads correct
Supabase DB for a staging plan), the OG-card `<meta property="og:url">`
is computed from this hardcoded literal. The unfurled WhatsApp preview
links the user from staging→prod on tap. Subtler than A6 — the preview
renders correctly (because A6 fix lets it find the plan), then the tap
opens prod web player which 404s. Sister bug to A6, will be missed if
A6 is fixed in isolation.

**Recommended fix:** Compute `planUrl` from the incoming request's
origin (`new URL(request.url).origin`) which Vercel sets to the actual
deploy hostname. Or expose the origin via env var the same way A6's
Supabase fix would.

### A7 — `web-portal/src/components/SessionsList.tsx` hardcodes player URL

**Severity:** MEDIUM (PERSISTS)

**Where:** `web-portal/src/components/SessionsList.tsx:328`

**Current value:** `` return `https://session.homefit.studio/p/${planId}`; ``

**Why it's a problem:** Staging portal renders session links pointing
at prod web player. Symptom: tester clicks a session card in the
staging portal, lands on prod web player which 404s the plan.

**Recommended fix:** Read `process.env.NEXT_PUBLIC_WEB_PLAYER_BASE_URL`
with a thrown error on missing (or a clean fallback to the same-origin
swap if the portal knows it's at `staging.manage.homefit.studio`).

### A8 — `web-portal/src/app/audit/page.tsx` hardcodes player URL for audit-row link

**Severity:** MEDIUM (PERSISTS)

**Where:** `web-portal/src/app/audit/page.tsx:811`

**Current value:** `` href: `https://session.homefit.studio/p/${row.refId}` ``

**Why it's a problem:** Same as A7 but for the audit-log "open in
player" link. Staging audit rows link to prod player.

**Recommended fix:** Same as A7.

### A9 — `referralUrl()` falls back to prod manage URL

**Severity:** MEDIUM (PERSISTS)

**Where:** `web-portal/src/lib/referral-share.ts:7`, `web-portal/src/app/network/page.tsx:103`

**Current value:** `process.env.NEXT_PUBLIC_APP_URL ?? 'https://manage.homefit.studio'`

**Why it's a problem:** Same silent-fallback pattern as A5. If
`NEXT_PUBLIC_APP_URL` isn't set on a staging Vercel deploy, the
referral share URL points at prod even though the user is on staging.

**Recommended fix:** Throw on missing env var (strict-fail).

### A10 — Google Fonts preconnect hardcoded (deliberate)

**Severity:** INFORMATIONAL (PERSISTS)

**Where:** `web-portal/src/app/layout.tsx:23,26,30`

**Why it's flagged:** External service URLs (same category as `wa.me`,
`payfast.co.za`). No action.

### A11 — SnackBar copy says "manage.homefit.studio/getting-started" in staging builds (NEW)

**Severity:** MEDIUM (NEW — partial-fix leakage from PR #304)

**Where:**

- `app/lib/screens/home_screen.dart:336` (primary banner fallback SnackBar)
- `app/lib/screens/home_screen.dart:1373` (header banner fallback SnackBar)

**Current value:**

```dart
'Visit manage.homefit.studio/getting-started'
```

**Why it's a problem:** PR #304 made the tap target route through
`AppConfig.portalOrigin` (correct — opens
`staging.manage.homefit.studio/...` on a staging build). But this
fallback SnackBar fires when the URL fails to launch externally, and
its message hardcodes `manage.homefit.studio` as a display string. A
staging tester whose external browser is misconfigured sees "Visit
manage.homefit.studio/..." — they'd then manually browse to the wrong
host. Mismatch between what the app opens and what it tells the user
to open.

Concrete failure mode: tester sees SnackBar after Safari fails to
launch (rare, but reproducible if a default-browser tweak fires),
follows the visible URL → lands on prod portal → enrols a prod
practice account → wonders why their staging-build credits aren't
visible.

**Recommended fix:** Build the display string from `AppConfig.portalOrigin`:
extract host (e.g. `Uri.parse(AppConfig.portalOrigin).host` →
`staging.manage.homefit.studio`) and interpolate. Or just stop showing
a URL in the SnackBar — "Couldn't open the walkthrough — check your
default browser" is enough.

### A12 — Out-of-credits credit chip says "manage.homefit.studio" in staging builds (NEW)

**Severity:** MEDIUM (NEW — partial-fix leakage from PR #304)

**Where:** `app/lib/widgets/home_credits_chip.dart:150`

**Current value:**

```dart
"You're out of credits. Top up at manage.homefit.studio "
"when you're at your computer."
```

**Why it's a problem:** Same class as A11. The user-facing string on
the Home credits chip tells a staging tester to top up at the prod
portal. The string is `const`, so flipping to a getter requires either
a runtime build or a `String.fromEnvironment` derived string at top
level.

The Reader-App memory rule says this surface MUST stay non-tappable
(no purchase link), so we can't route through `portalLink`. We CAN
route through `AppConfig.portalOrigin` as a display string.

**Recommended fix:** Construct the text from `Uri.parse(AppConfig.portalOrigin).host`
at build time of the widget (not as `const`). Or store the host alone
as a top-level getter on `AppConfig` (`AppConfig.portalHost` →
`manage.homefit.studio` / `staging.manage.homefit.studio`) and
interpolate.

### A13 — Comment-block + doc strings still reference `manage.homefit.studio` verbatim (NEW, LOW)

**Severity:** LOW (NEW — code-hygiene only)

**Where:**

- `app/lib/screens/settings_screen.dart:50,159,229` (comments)
- `app/lib/screens/studio_mode_screen.dart:2893` (comment)
- `app/lib/services/upload_service.dart:426` (comment)
- `app/lib/screens/home_screen.dart:313,568,615,1289` (doc comments)
- `app/lib/services/share_kit_templates.dart:28` (docstring example URL)
- `app/lib/screens/unified_preview_screen.dart:42` (doc comment)

**Why it's a problem:** Comments / docstrings reference the prod
hostname as if it's the only host. After PR #304, the canonical
phrasing should be "the portal" or "`AppConfig.portalOrigin`". A
future engineer reading "opens manage.homefit.studio/getting-started"
might assume the URL is constant and write a new hardcoded callsite.
Code-hygiene only — no runtime impact.

**Recommended fix:** Sweep doc comments to refer to
`AppConfig.portalOrigin` instead of the literal host. Optional polish.

## B. Bundle IDs and URL Schemes

### B1 — `AppConfig.oauthRedirectUrl` env-aware

RESOLVED in PR #304 commit `c761eb1`. `config.dart:227` is now a
getter returning `studio.homefit.app.dev://login-callback` for
non-prod and `studio.homefit.app://login-callback` for prod. Supabase
auth allowlist update (companion to this fix) noted on the merge
commit message; see I3 below for the explicit allowlist entries that
should be present.

### B2 — `studio.homefit.app` literal in os_log subsystem strings

**Severity:** LOW (PERSISTS)

**Where:**

- `app/ios/Runner/ClientAvatarProcessor.swift:56` — `subsystem: "studio.homefit.app"`
- `app/ios/Runner/AvatarCameraChannel.swift:52` — `OSLog(subsystem: "studio.homefit.app", category: ...)`

**Why it's a problem:** Console.app filtering by subsystem
(`subsystem:studio.homefit.app`) won't surface dev-build logs since
the dev build's bundle ID is `studio.homefit.app.dev`. Diagnostics
docs saying "filter by subsystem studio.homefit.app" silently exclude
dev builds. Carl debugging a dev-only issue would see zero logs and
assume the channel is broken.

**Recommended fix:** Read from `Bundle.main.bundleIdentifier` at
log-init time. Documented workaround until then: dev builds need
`subsystem:studio.homefit.app.dev`.

### B3 — `com.raidme.*` MethodChannel names (deliberate legacy)

**Severity:** INFORMATIONAL (PERSISTS)

CLAUDE.md explicitly marks these as deliberate debt. No action.

### B4 — `com.raidme.raidme` in Android + macOS configs (deliberate legacy)

**Severity:** INFORMATIONAL (PERSISTS)

iOS is the only ship surface for MVP. No action.

### B5 — Bundle ID hardcoded in install scripts

**Severity:** LOW (PARTIALLY RESOLVED — install-device.sh now dead-code only)

**Where:**

- `install-sim.sh:24` — `BUNDLE=studio.homefit.app` USED at lines 145 (uninstall) + 169 (launch)
- `install-device.sh:42` — `BUNDLE=studio.homefit.app` DEAD VARIABLE (no usages on staging)

**Why it's a problem (install-sim.sh):** The Debug build the script
produces has bundle `studio.homefit.app.dev`. So `uninstall studio.homefit.app`
on line 145 is a no-op on a clean sim, and `simctl launch studio.homefit.app`
on line 169 silently launches the wrong app (or the same wrong app
that's been there since the last manual install). Sim install
"completes" but the launched bundle is whatever's already there.

**Why it's a problem (install-device.sh):** None — `BUNDLE` on line 42
is set but never referenced in the remainder of the script.
`xcrun devicectl device install app` on line 248 reads the bundle ID
from the .app bundle's Info.plist directly. The variable is dead code,
LOW for cleanup.

**Recommended fix:**

- `install-sim.sh`: read the actual bundle ID from the built
  `.app/Info.plist` after build (`plutil -extract CFBundleIdentifier raw`).
- `install-device.sh`: remove the dead `BUNDLE` line.

### B6 — Bundle ID in `build-testflight.sh` (no hardcode)

**Severity:** INFORMATIONAL (PERSISTS — documenting clean state)

`build-testflight.sh` uses the Release config (bundle ID set in
pbxproj). No action.

## C. Supabase Project Refs and Keys

### C1 — Prod Supabase URL + anon key hardcoded in `app/lib/config.dart`

**Severity:** LOW (PERSISTS — intentional per docs/CI.md §5)

**Where:** `app/lib/config.dart:37-40, 45-48`

Anon keys are public-by-design. Rotation is rare; the staging branch
lets us validate a key swap before shipping. Listed for completeness.

### C2 — Prod project ref + anon key hardcoded in install scripts

**Severity:** LOW (PERSISTS)

**Where:** `install-sim.sh:42-44, 48` and `install-device.sh:75-77, 82`

Same as C1. Mitigated by the install scripts' staging/branch paths
using `supabase projects api-keys` via CLI.

### C3 — Prod URL + key hardcoded in `build-testflight.sh`

**Severity:** LOW (PERSISTS)

**Where:** `build-testflight.sh:29-30`

Documented prod-release path. Defence-in-depth. No action required.

### C4 — Prod project ref in CI workflow

**Severity:** INFORMATIONAL (PERSISTS)

**Where:** `.github/workflows/supabase-branch-vault.yml:68`

Contextual config for a prod-targeting workflow. Not a secret.

### C5 — Prod URL hardcoded inside `supabase/migrations/20260511065443_baseline.sql`

**Severity:** MEDIUM (PERSISTS)

**Where:** `supabase/migrations/20260511065443_baseline.sql:1611`

**Current value:** A literal `'https://yrwcofhovrcydootivjx.supabase.co/storage/v1/object/public/media/'`
inside the `get_plan_full` RPC body.

**Why it's a problem:** Baseline migration is what Supabase Branching
applies to EVERY per-PR DB. Branch DBs created off this baseline mint
public-media URLs pointing at PROD storage. Test plans against a
branch DB get broken line-drawing thumbnails (URLs point at prod
bucket where files don't exist).

**Recommended fix:** Read base URL from `vault.secrets`
(`supabase_url`) the same way `sign_storage_url` already does.
`supabase-branch-vault.yml` populates that secret per-branch.

### C6 — Prod URL in archived patch SQL (historical reference)

**Severity:** INFORMATIONAL (PERSISTS)

`supabase/archive/*.sql` files are historical reference per CLAUDE.md.
CI doesn't pick them up. No action.

### C7 — `placeholder-anon-key` fallback in web-portal clients

**Severity:** LOW (PERSISTS)

**Where:** `web-portal/src/lib/supabase-browser.ts:14`,
`web-portal/src/lib/supabase-server.ts:13`, `web-portal/src/middleware.ts:44`

A misconfigured Vercel deploy with missing env var won't crash at
module load. First auth/network call returns "invalid API key". LOW
because the failure is loud at runtime, just not at build.

**Recommended fix:** Throw at module load if either env var is
missing (strict-fail policy).

## D. UUIDs and Sentinel IDs

### D1 — Sentinel UUIDs in `app/lib/config.dart`

**Severity:** MEDIUM (PERSISTS)

**Where:** `app/lib/config.dart:204-207`

Sentinels exist in prod DB seeds, don't exist in staging-branch / per-PR DBs.
`auth_service.dart` claim path falls back to a fresh personal practice
if the sentinel is missing — correct behaviour today. Future logic
that requires the sentinel would break in non-prod. No concrete
failure mode visible today.

**Recommended fix:** CI check ("if app code uses `sentinelPracticeId`,
the seed migration must insert that uuid") in `tools/enforce_data_access_seams.py`.
Document in CI.md that the sentinel is a prod-only convenience.

### D2 — Sentinel UUID `00000000-...-000000000000` in baseline migration index

**Severity:** INFORMATIONAL (PERSISTS)

`COALESCE(exercise_id, '00...0'::uuid)` in a unique index. NULL-coalesce
sentinel; not data. No action.

### D3 — Carl's personal hardware UDIDs in install scripts

**Severity:** LOW (PERSISTS)

**Where:** `install-sim.sh:23` (`E4285EC5-...`), `install-device.sh:41` (`00008150-...`)

Other contributors would need to swap. Carl is sole developer today.

**Recommended fix:** Read from env var `HOMEFIT_DEVICE` with current
value as default. README note: "to find yours, run `xcrun devicectl list devices`".

### D4 — Apple `DEVELOPMENT_TEAM = J9R837QRR6` in project.pbxproj

**Severity:** LOW (PERSISTS)

**Where:** `app/ios/Runner.xcodeproj/project.pbxproj:524, 708, 732`

Carl's Apple Developer team ID. Carl is sole signer today. Not a
security issue (team IDs are public-ish).

**Recommended fix:** Document in `docs/TESTFLIGHT_PREP.md` that team
ID swap is required for other signers.

## E. Bundle / App Version

### E1 — App version sourced correctly from pubspec

**Severity:** INFORMATIONAL (PERSISTS)

**Where:** `app/pubspec.yaml:4` (currently `1.0.0+3`)

`bump-version.sh` is the only mutator. No drift.

### E2 — Web-player `PLAYER_VERSION` literal in `app.js`

**Severity:** LOW (PERSISTS)

**Where:** `web-player/app.js:20` — `const PLAYER_VERSION = 'v69-modal-first-desktop';`

Manually-maintained version string; can lie since git SHA is the real
build marker. Footer shows both; the human-readable string drifts.

**Recommended fix:** Retire `PLAYER_VERSION` (git SHA is sufficient).
Or auto-bump via a tagged-commit message hook.

### E3 — Service worker cache version

**Severity:** INFORMATIONAL (PERSISTS — bumped to v76 since previous audit)

**Where:** `web-player/sw.js:8` — `'homefit-player-v76-env-config'`

Deliberate manual bump per CLAUDE.md. (Note: CLAUDE.md still says v75
in places — minor doc drift.)

## F. Hardcoded Credentials or Merchant IDs

### F1 — `PAYFAST_PASSPHRASE=jt7NOE43FZPn` committed to `web-portal/.env.example`

**Severity:** MEDIUM (PERSISTS)

**Where:** `web-portal/.env.example:24`

Sandbox passphrase, but `.env.example` is committed to git. Comment
justifies for testing. Risks:

1. If Carl swaps the sandbox passphrase via PayFast dashboard, the
   example file silently lies.
2. No guard preventing this value from ending up in prod `.env`
   (developer copy-paste forget): prod signatures computed with
   sandbox passphrase → 100% of webhooks fail signature check →
   100% of purchases never credit a practice.

**Recommended fix:** Empty the value with comment "fill in your
merchant passphrase". Document the sandbox value in
`web-portal/README.md`. Add startup check that errors loudly if
`PAYFAST_PASSPHRASE` equals the sandbox value AND `PAYFAST_SANDBOX=false`.

### F2 — PayFast sandbox merchant ID + key fallback in `payfast.ts`

**Severity:** LOW (PERSISTS)

**Where:** `web-portal/src/lib/payfast.ts:163-165`

Public sandbox creds, gated on `sandbox` flag. Production gets `''`
and the route handler returns 500. Defensive AND correctly gated.

**Recommended fix:** Optional — remove the fallback entirely and
require env vars even for sandbox.

### F3 — `PAYFAST_IP_BLOCKS` hardcoded in both Next route AND edge function

**Severity:** LOW (PERSISTS)

**Where:** `web-portal/src/lib/payfast.ts:136-146`,
`supabase/functions/payfast-webhook/index.ts:42-50`

Two sources of truth. Drift risk on PayFast IP-range updates.

**Recommended fix:** Shared constants file, or move to `vault.secrets`,
or CI parity check (line-for-line equality).

### F4 — Apple `DEVELOPMENT_TEAM` (covered in D4)

Cross-reference. No separate entry.

## G. Hardcoded Paths

### G1 — Absolute `/Users/chm/dev/TrainMe` path in `config.dart` docstring

**Severity:** LOW (PERSISTS)

**Where:** `app/lib/config.dart:103` (inside a Dart docstring)

Cosmetic. Not load-bearing.

**Recommended fix:** Replace with `--dart-define=GIT_SHA=$(git rev-parse --short HEAD)`.

### G2 — Absolute path in cron snippet in `tools/publish-health-ping/`

**Severity:** LOW (PERSISTS)

**Where:** `tools/publish-health-ping/README.md:43`,
`tools/publish-health-ping/ping.sh:39`

Cron example is Carl-machine-specific. README clearly says it's a
Carl-runs-this tool.

**Recommended fix:** Replace with `cd ~/your/path/to/repo/tools/publish-health-ping`
in README.

## H. Magic Constants That Should Be Env-Aware

### H1 — `recycleBinRetentionDays = 7` always

**Severity:** INFORMATIONAL (PERSISTS)

Stable product policy per CLAUDE.md R-01.

### H2 — Conversion-service timeouts (30s, 10s, 3min) hardcoded

**Severity:** INFORMATIONAL (PERSISTS)

Tuned values for AVFoundation/iOS performance. Same on every env.

### H3 — Credit-pricing threshold `75 * 60` seconds

**Severity:** LOW (PERSISTS)

**Where:** `app/lib/config.dart:248`

Product policy. Drift risk if changed (portal/terms copy + `creditCostForDuration`
need synchronised update).

### H4 — Signup-bonus credit amounts (3 organic, 5 referral)

**Severity:** LOW (PERSISTS)

**Where:** `app/lib/config.dart:238, 243` AND
`supabase/migrations/20260511065443_baseline.sql:678, 850`

Drift risk between Dart constants (display-only) and DB function
(actual grant). Confusing if they diverge.

**Recommended fix:** Make Dart constants read from a DB-served config
row, OR accept the drift risk and document in CLAUDE.md.

## I. Other Findings Worth Flagging

### I1 — Two-source-of-truth for the prod Supabase URL inside the `get_plan_full` RPC body

**Severity:** MEDIUM (covered in C5). Cross-reference.

### I2 — `placeholder-anon-key` is a real string committed to source

**Severity:** LOW (covered in C7). Cross-reference.

### I3 — Missing `staging.session.homefit.studio` / `staging.manage.homefit.studio` entries in Supabase auth allowlist

**Severity:** MEDIUM (PERSISTS — though B1 fix on staging means it's now load-bearing for any tester)

**Why it's a problem:** Per CLAUDE.md the Supabase auth redirect
allowlist includes `https://manage.homefit.studio/**` + localhost +
`studio.homefit.app://` schemes. With PR #304 now shipped, magic-link
emails from a staging dev build use redirect
`studio.homefit.app.dev://login-callback`. The allowlist needs
`studio.homefit.app.dev://**` for that to deep-link correctly. CLAUDE.md
notes the staging-branch project (`vadjvkmldtoeyspyoqbx`) was updated
on 2026-05-12 — verify both projects (prod + staging) have the right
entries.

For browser flows in staging (if/when we wire OAuth providers there):
`https://staging.manage.homefit.studio/**` + `https://staging.session.homefit.studio/**`
need allowlist entries too. Without them, redirects silently fall back
to Site URL (per `gotcha_supabase_redirect_silent_fallback.md`).

**Recommended fix:** Audit the Supabase auth URL allowlist on BOTH
projects (prod + staging) via Management API. Capture state in a
runbook so future engineers can re-verify.

### I4 — `web-portal/.env.example` commits prod Supabase URL + anon key

**Severity:** LOW (PERSISTS)

**Where:** `web-portal/.env.example:3-4`

Developer copying `.env.example` → `.env` runs local portal against
prod Supabase by default. Mitigated by RLS but a footgun.

**Recommended fix:** Switch example to staging URL + staging anon
key. Strict-fail at startup if `SUPABASE_URL` equals prod AND
`NODE_ENV !== 'production'`.

### I5 — `web-player/api.js` config-injection pattern (model)

**Severity:** INFORMATIONAL (PERSISTS)

**Where:** `web-player/api.js:113-133`

Good pattern — config via `window.HOMEFIT_CONFIG` populated by
`web-player/build.sh`. No hardcoded supabase URL/key in `api.js`.
Listed as the model the OTHER surfaces (especially `middleware.js`
A6/A6b) should mirror.

## What to fix in the next release

Ranked HIGH only (no remaining CRITICAL — B1 RESOLVED).

1. **A6 (HIGH)** — Make `web-player/middleware.js:1-2` read Supabase
   config from `process.env`. Add strict-fail on missing. Same policy
   as `build.sh`. Without this, every staging-deploy WhatsApp unfurl
   404s.
2. **A6b (HIGH, NEW — pair with A6)** — Compute `planUrl` on
   `web-player/middleware.js:62` from the incoming request origin
   instead of the prod literal. OG card click leads to a working URL.
3. **A11 (MEDIUM but partial-fix continuation of PR #304)** — Make
   the SnackBar fallback URL display string in `home_screen.dart:336,1373`
   env-aware. Use `Uri.parse(AppConfig.portalOrigin).host` or drop
   the URL from the SnackBar.
4. **A12 (MEDIUM, same class as A11)** — Make the out-of-credits
   credit-chip copy in `home_credits_chip.dart:150` env-aware. Same
   approach as A11.
5. **A5 / A7 / A8 / A9 (cluster, MEDIUM)** — Strict-fail the web-portal's
   env-var reads. Five callsites currently `??` fall back to prod URLs.
   Treat as one fix (all use the same pattern).
6. **C5 (MEDIUM)** — Replace the prod URL literal inside the
   `get_plan_full` RPC body in `supabase/migrations/20260511065443_baseline.sql`
   with a `vault.secrets`-backed value. The vault secret is already
   populated per-branch by `supabase-branch-vault.yml`.
7. **I3 (MEDIUM — pair with B1)** — Audit + confirm Supabase auth
   redirect allowlist entries on BOTH prod and staging projects.
   Required for B1's fix to actually work end-to-end.

Memory rules to surface:

- `feedback_no_direct_db_access.md` — already covers DB seam discipline.
- New memory entry "Every user-FACING string that names the prod
  hostname should be derived from `AppConfig.portalOrigin`, not a
  literal" — flag for Carl. PR #304 caught the URL-construction sites;
  the display-string sites (A11/A12) are the next class to sweep.
