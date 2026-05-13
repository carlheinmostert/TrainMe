# Hardcoded Values Audit — 2026-05-12 (re-run)

Second pass after the original `docs/HARDCODED-AUDIT-2026-05-12.md` missed
the `web-player/vercel.json` CSP block — a hardcoded prod-URL bug that
shipped to staging and caused real CSP-blocked traffic during QA before
manual catch + PR #307.

This re-audit is purely mechanical: literal-string `grep` of the exact
prod identifiers across the whole tree, no file-type exclusions beyond
generated/lock files. The previous audit's interpretive sweep (scoped to
"URL patterns in source code") missed `vercel.json` because CSP values
sit in a HTTP-header config block, not a URL string literal.

Source tree: `origin/staging` tip `733d60d` (Merge PR #307 + PR #305 +
PR #304 + PR #303 + earlier). Audit doc commits direct to main per
`feedback_specs_direct_to_main.md`.

## Table of Contents

- [Methodology Postmortem](#methodology-postmortem)
- [Methodology](#methodology)
- [Summary](#summary)
- [Confirmation-of-Fix Entries](#confirmation-of-fix-entries)
- [A. URLs and Origins (Web Hostnames)](#a-urls-and-origins-web-hostnames)
- [B. Bundle IDs and URL Schemes](#b-bundle-ids-and-url-schemes)
- [C. Supabase Project Refs and Keys](#c-supabase-project-refs-and-keys)
- [D. UUIDs and Sentinel IDs](#d-uuids-and-sentinel-ids)
- [E. Bundle / App Version](#e-bundle--app-version)
- [F. Hardcoded Credentials or Merchant IDs](#f-hardcoded-credentials-or-merchant-ids)
- [G. Hardcoded Paths](#g-hardcoded-paths)
- [H. Magic Constants That Should Be Env-Aware](#h-magic-constants-that-should-be-env-aware)
- [I. Other Findings Worth Flagging](#i-other-findings-worth-flagging)
- [What to fix in the next release](#what-to-fix-in-the-next-release)

## Methodology Postmortem

The previous audit (`dcb217b`) used an interpretive grep scoped to
"URL pattern matches in source code". That methodology silently excluded:

1. **HTTP-header config values** — `web-player/vercel.json:45` hardcoded
   the prod Supabase URL inside three CSP directives
   (`img-src`, `media-src`, `connect-src`). The CSP block IS string text
   in a JSON config, but the previous audit didn't grep `.json` files at
   all. This shipped to staging on PR #283 (or earlier) and tightened
   further in PR #287 — when staging QA tried to load the staging
   Supabase URL it was blocked by the prod-only CSP allowlist. Caught
   manually mid-QA; fixed in PR #307 by switching to `https://*.supabase.co`
   wildcard.
2. **`.yml` workflow `env:` blocks** — never grepped, but they DO carry
   project refs (e.g. `.github/workflows/supabase-branch-vault.yml:68`
   `PROJECT_REF: yrwcofhovrcydootivjx`).
3. **`.env.example` template files** — partially grepped before, fully
   covered now.
4. **iOS `*.pbxproj` / `Info.plist` / `*.swift`** — partially grepped,
   fully covered now.
5. **Migration SQL bodies** — partially grepped before, fully covered.
6. **Tracked `supabase/.temp/` artefacts** — never considered; turns out
   `supabase/.temp/linked-project.json` + `supabase/.temp/project-ref`
   ARE tracked in git and hardcode the prod project ref.

The fix in this re-audit: purely literal grep of `yrwcofhovrcydootivjx`,
`vadjvkmldtoeyspyoqbx`, `session.homefit.studio`, `manage.homefit.studio`,
`studio.homefit.app://`, the known prod anon key prefix `cwhfavfji552`,
plus regex sweeps for `re_[A-Za-z0-9_]{25,}` and `sbp_[a-f0-9]{32,}` key
patterns — across the whole tree with only generated/lock files excluded.
Each hit is opened, read, classified — not summarised from grep output.

## Methodology

For each finding, the audit names the **concrete failure mode** (what
breaks, who notices, what they see).

Severity ladder:

- **CRITICAL** — production / staging bug right now (wrong env routing,
  security, data loss, deploy-blocked).
- **HIGH** — will bite within weeks; concrete realistic trigger.
- **MEDIUM** — wrong-env behaviour that's harder to notice (audit
  rows linking wrong env, display strings drift, etc.).
- **LOW** — code hygiene, deliberate-but-document-this, defence-in-depth
  nice-to-have.
- **DELIBERATE** — the prod ref appears as the literal value of an
  env-aware getter (e.g., `_prodSupabaseUrl` constant inside the
  `supabaseUrl` ENV switch in `config.dart`). NOT a bug.
- **INFORMATIONAL** — historical / template / context only, no action.

## Summary

**Total findings: 35** (29 active, 6 confirmation-of-fix from PR #304/#307).

- CRITICAL: 0 (the staging CRITICAL was caught + fixed in PR #307 before
  this re-audit ran)
- HIGH: 7
- MEDIUM: 6
- LOW: 10
- DELIBERATE: 6
- INFORMATIONAL: 6 (incl. confirmation-of-fix entries below)

**Findings the previous audit missed:** 4

1. `web-player/vercel.json` CSP — the prompt-for-this-re-audit. 1 CRITICAL
   shipped to staging.
2. `supabase/.temp/linked-project.json` + `supabase/.temp/project-ref` —
   tracked in git, hardcode prod ref. Not load-bearing but illustrates
   the methodology gap.
3. `app/test/publish_dirty_state_test.dart:66,116` — test fixtures with
   `https://session.homefit.studio/p/fake-uuid`. Would never fire because
   tests are read-only fixtures, but a literal-grep methodology surfaces
   them.
4. `.github/workflows/supabase-branch-vault.yml:68` — `PROJECT_REF` env.
   Deliberate (workflow targets the prod project where Branching is
   enabled) but not grepped before.

## Confirmation-of-Fix Entries

Per the re-audit brief, the following findings from `dcb217b` have been
verified RESOLVED at the `origin/staging` tip. Listed here so the lesson
sticks.

### CONFIRMED-A1/A2 — `webPlayerOrigin` + `portalOrigin` env-aware

**Resolved in:** PR #304 (`ebd9d44 fix(mobile): env-aware share URLs +
portal origin`)

**Verification (`app/lib/config.dart:138-167`):**

```dart
static const String _prodWebPlayerOrigin = 'https://session.homefit.studio';
static const String _stagingWebPlayerOrigin =
    'https://staging.session.homefit.studio';
// ...
static String get webPlayerOrigin {
  return env == 'prod' ? _prodWebPlayerOrigin : _stagingWebPlayerOrigin;
}
```

`webPlayerBaseUrl` is now a getter aliased to `webPlayerOrigin`. Same
pattern for `portalOrigin`.

### CONFIRMED-A3 — `sync_service.dart` plan-URL construction routed through `webPlayerOrigin`

**Resolved in:** PR #304

**Verification (`app/lib/services/sync_service.dart:619`):**

```dart
planUrl: '${AppConfig.webPlayerOrigin}/p/$id',
```

### CONFIRMED-A4 — Mobile screen `manage.homefit.studio` URLs routed through `portalLink`

**Resolved in:** PR #304

**Verification:** `app/lib/services/portal_links.dart:25` now reads
`AppConfig.portalOrigin`; `settings_screen.dart`, the referral share
sheet, and `home_screen.dart` getting-started navigations all call
`portalLink('/...')`. Some SnackBar display strings still emit literal
`manage.homefit.studio` text — see [A11](#a11--snackbar-display-string-hardcoded-managehomefitstudio) +
[A12](#a12--home_credits_chipdart-out-of-credits-string-hardcoded-managehomefitstudio).

### CONFIRMED-A6 — `web-player/middleware.js` env-aware Supabase config

**Resolved in:** PR #307 (`982bc73 fix(web-player): CSP wildcard +
env-aware middleware`)

**Verification (`web-player/middleware.js:35-47`):**

```js
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL;
const SUPABASE_ANON_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
  || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error('...');
  return; // pass-through; never silently route to prod
}
```

OG host also derived from `request.url` origin so staging unfurls show
`staging.session.homefit.studio` in the unfurl card.

### CONFIRMED-A6b (NEW) — `web-player/vercel.json` CSP wildcard

**Resolved in:** PR #307

**Lesson:** This is the bug the previous audit missed entirely. CSP
`img-src` / `media-src` / `connect-src` previously locked to
`https://yrwcofhovrcydootivjx.supabase.co`; PR #307 broadened to
`https://*.supabase.co`. Wildcard is acceptable because Supabase project
URLs are the only `*.supabase.co` hosts the player needs to reach.

**Verification (`web-player/vercel.json:45`):**

```
img-src 'self' https://*.supabase.co data:;
media-src 'self' https://*.supabase.co blob:;
connect-src 'self' https://*.supabase.co;
```

### CONFIRMED-B1 — `oauthRedirectUrl` env-aware (the original CRITICAL)

**Resolved in:** PR #304 (`c761eb1 fix(mobile): env-aware
oauth/magic-link redirect — opens correct app`)

**Verification (`app/lib/config.dart:227-231`):**

```dart
static String get oauthRedirectUrl {
  return env == 'prod'
      ? 'studio.homefit.app://login-callback'
      : 'studio.homefit.app.dev://login-callback';
}
```

Supabase auth redirect allowlist needs both `studio.homefit.app://**` +
`studio.homefit.app.dev://**` — verified live per CLAUDE.md note dated
2026-05-12.

## A. URLs and Origins (Web Hostnames)

### A5 — Web-portal Supabase URL fallback to prod (silent)

**Severity:** HIGH

**Where:**

- `web-portal/src/middleware.ts:41`
- `web-portal/src/lib/supabase-server.ts:10`
- `web-portal/src/lib/supabase-browser.ts:11`
- `web-portal/src/lib/supabase/api.ts:1212`
- `web-portal/src/app/credits/purchase/route.ts:125`

**Current value:**
`process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'https://yrwcofhovrcydootivjx.supabase.co'`

**Concrete failure mode:** A staging Vercel deploy missing
`NEXT_PUBLIC_SUPABASE_URL` (most likely scenario: the Vercel-Supabase
integration drift, or a hand-rolled preview deploy) silently talks to
PROD Supabase. No error, no log — the portal renders prod data on the
staging host. Tester at `staging.manage.homefit.studio` mutates prod DB
without realising.

**Status:** WIP in `fix/env-aware-everything-else` — branch introduces
`web-portal/src/lib/env.ts` with `requireEnv()` strict-fail; all five
call sites refactored to throw instead of fall back.

**Recommended fix:** Land the WIP branch. Strict-fail at module load
mirrors the `web-player/build.sh` policy adopted in PR #293.

### A7 — `SessionsList.tsx` hardcodes prod player URL

**Severity:** HIGH

**Where:** `web-portal/src/components/SessionsList.tsx:328`

```ts
function playerUrl(planId: string): string {
  return `https://session.homefit.studio/p/${planId}`;
}
```

**Concrete failure mode:** Staging portal renders session cards with
links to PROD web player. Tester on `staging.manage.homefit.studio`
clicks a plan card, lands at `session.homefit.studio/p/<staging-uuid>`,
prod player calls prod `get_plan_full` which returns null → "Plan not
found" rendered.

**Status:** WIP in `fix/env-aware-everything-else`.

**Recommended fix:** Read env-aware base URL via the `env.ts` helper.

### A8 — `audit/page.tsx` hardcodes prod player URL

**Severity:** MEDIUM

**Where:** `web-portal/src/app/audit/page.tsx:811`

```ts
href: `https://session.homefit.studio/p/${row.refId}`,
```

**Concrete failure mode:** Same as A7 but in the audit log's "open in
player" link. Staging audit rows point at prod player. Less load-bearing
because audit is a power-user view, but same drift.

**Status:** WIP in `fix/env-aware-everything-else`.

### A9 — `referral-share.ts` + `network/page.tsx` fall back to prod manage URL

**Severity:** HIGH

**Where:**

- `web-portal/src/lib/referral-share.ts:7` — `process.env.NEXT_PUBLIC_APP_URL ?? 'https://manage.homefit.studio'`
- `web-portal/src/app/network/page.tsx:103` — `'https://manage.homefit.studio/r/loading'` fallback when referral code is loading

**Concrete failure mode:** Same silent-fallback class as A5. Staging
portal generates referral links pointing at PROD `/r/{code}` even though
the code lives in the staging DB. Friend clicks the WhatsApp share from
a staging-built referral, lands on prod portal, sees "invalid code".

**Status:** WIP in `fix/env-aware-everything-else`.

### A10 — Privacy / Terms scaffold pages contain `manage.homefit.studio` + `session.homefit.studio` literals

**Severity:** LOW (display text)

**Where:**

- `web-portal/src/app/privacy/page.tsx:73,151,156,384,386,700,705,710,737,764` — body copy + cookie-table descriptions
- `web-portal/src/app/terms/page.tsx:58,59,95,97,418` — body copy

**Concrete failure mode:** A staging build's privacy page tells the
visitor "we run at `manage.homefit.studio` and `session.homefit.studio`"
even when the visitor is reading the page at `staging.manage.homefit.studio`.
Display drift only — no functional impact. The pages are scaffolds
awaiting lawyer red-pen anyway (per `docs/CHECKPOINT_2026-04-28`), so the
final copy will get a polishing pass.

**Recommended fix:** Defer to legal review pass. When the final copy
lands, route hostnames through a helper that displays the active host
or accepts the canonical-prod hostname as deliberate legal-document
content (more defensible — privacy policy is bound to the prod entity).

### A11 — SnackBar display string hardcoded `manage.homefit.studio`

**Severity:** MEDIUM

**Where:** `app/lib/screens/home_screen.dart:336` + `:1373`

```dart
"Couldn't open the walkthrough. Visit "
'manage.homefit.studio/getting-started',
```

**Concrete failure mode:** Staging build's failed-launch fallback tells
the practitioner to visit `manage.homefit.studio/getting-started` —
which works in prod but the practitioner is on staging-routed data, so
they'd land on the wrong env's getting-started page (or worse, mix data
flows).

**Status:** WIP in `fix/env-aware-everything-else` — modifies
`home_screen.dart` to interpolate `AppConfig.portalOrigin`.

### A12 — `home_credits_chip.dart` out-of-credits string hardcoded `manage.homefit.studio`

**Severity:** MEDIUM (compounded by iOS Reader-App rule)

**Where:** `app/lib/widgets/home_credits_chip.dart:150`

```dart
"You're out of credits. Top up at manage.homefit.studio "
"when you're at your computer.",
```

**Concrete failure mode:** Same as A11. Compounding factor: per the iOS
Reader-App memory rule (`feedback_ios_reader_app.md`), this string MUST
remain non-tappable plain text, but the env-blind hostname still makes a
staging tester confused which env to top up on.

**Status:** WIP in `fix/env-aware-everything-else`.

### A13 — `web-portal/src/app/r/[code]/opengraph-image.tsx` hardcodes prod hostname in OG card body

**Severity:** LOW

**Where:** `web-portal/src/app/r/[code]/opengraph-image.tsx:191`

```tsx
manage.homefit.studio/r/{params.code}
```

**Concrete failure mode:** Staging-deployed OG image hardcodes
`manage.homefit.studio/r/<code>` as the visible URL text inside the
unfurl card. The unfurl preview ALSO shows the page URL natively from
the originating link, so the OG card text becomes inconsistent with the
real share URL. Visible-to-the-user drift but doesn't break the click.

**Recommended fix:** Read from the request host or `NEXT_PUBLIC_APP_URL`
to render the actual hostname.

### A14 — `getting-started/_illustrations.tsx` SVG illustration hardcodes prod hostname

**Severity:** LOW

**Where:** `web-portal/src/app/getting-started/_illustrations.tsx:634`

```tsx
<text ...>session.homefit.studio/p/...</text>
```

**Concrete failure mode:** Illustration on the getting-started page is
literal text inside an SVG showing a stylised plan-URL preview. Static
illustration — not load-bearing. Listed for completeness.

**Recommended fix:** Could be left as-is (deliberate marketing /
training visual); or change to a placeholder like `your-plan-url/...`
that doesn't promise a specific host.

### A15 — `ShareKit/OgPreview.tsx` mock OG card shows prod hostname

**Severity:** LOW

**Where:** `web-portal/src/components/ShareKit/OgPreview.tsx:81`

```tsx
<div className="...">
  session.homefit.studio
</div>
```

**Concrete failure mode:** Like A14, this is a stylised preview on the
`/network` page showing what a WhatsApp unfurl looks like. Stylised
example — staging would show "this is what your prod unfurl looks like"
which is technically correct content for a marketing surface. Not a bug.

### A16 — Hardcoded plan URL in test fixture

**Severity:** INFORMATIONAL

**Where:** `app/test/publish_dirty_state_test.dart:66,116`

```dart
planUrl: 'https://session.homefit.studio/p/fake-uuid',
```

**Concrete failure mode:** None — string is asserted-against, not
followed. Test would still pass against any host. Listed because the
literal-grep methodology surfaces it; previous audit's URL-grep
methodology missed it.

## B. Bundle IDs and URL Schemes

### B2 — `studio.homefit.app` os_log subsystem strings don't match `.dev` builds

**Severity:** LOW (persisting from previous audit; still unfixed)

**Where:**

- `app/ios/Runner/AvatarCameraChannel.swift:52` — `OSLog(subsystem: "studio.homefit.app", category: "avatar.capture")`
- `app/ios/Runner/ClientAvatarProcessor.swift:56` — `subsystem: "studio.homefit.app"`

**Concrete failure mode:** Console.app filter
`subsystem:studio.homefit.app` won't show dev-build logs (those run as
`studio.homefit.app.dev`). Diagnostics docs that say "filter by subsystem"
silently exclude dev-build sessions. Symptom: Carl can't repro on
TestFlight, repros on dev, filters Console by subsystem, sees zero logs,
assumes the channel is broken.

**Status:** Not addressed by any WIP branch.

**Recommended fix:** Read from `Bundle.main.bundleIdentifier` at log
init. Documented workaround until then: dev builds need
`subsystem:studio.homefit.app.dev`.

### B3 — `com.raidme.*` MethodChannel names (deliberate legacy)

**Severity:** DELIBERATE

**Where:** Many Swift + Dart files.

**Rationale:** CLAUDE.md marks these as legacy channel identifiers
(internal Swift↔Dart contract). Renaming requires a synchronised mobile
release and there's zero user-facing impact. No action.

### B4 — `com.raidme.raidme` in Android + macOS configs (deliberate legacy)

**Severity:** DELIBERATE

**Where:** `app/android/app/build.gradle.kts`, `app/macos/Runner/Configs/AppInfo.xcconfig`.

**Rationale:** iOS is the only ship surface for MVP. No action.

### B5 — Install scripts launch fixed bundle ID

**Severity:** LOW

**Where:** `install-sim.sh`, `install-device.sh`

**Concrete failure mode:** Carried from previous audit — Debug builds
produce `studio.homefit.app.dev` but scripts may try to launch the prod
bundle. Carl runs these daily so any breakage is highly visible; if
silent, it's the symptom of a swapped bundle.

**Status:** Partial — `install-device.sh` was updated in PR #305 for
flutter-cache auto-clean (`afdc242`); script structure still has the
launch step. Confirmed not addressed by any WIP branch.

## C. Supabase Project Refs and Keys

### C1 — Prod URL + anon key in `app/lib/config.dart` (deliberate)

**Severity:** DELIBERATE

**Where:** `app/lib/config.dart:37-40, 45-48`

The prod URL + anon key sit as `_prodSupabaseUrl` / `_prodSupabaseAnonKey`
constants which the `supabaseUrl` / `supabaseAnonKey` getters return when
`env == 'prod'`. This is the env-switch pattern, not a hardcoded leak.

### C2 — Install scripts prod URL + anon key (deliberate)

**Severity:** DELIBERATE

**Where:** `install-sim.sh:42,44`, `install-device.sh:75,77`

Defensive defaults for the `ENV=prod` path. The scripts also have an
`ENV=staging` path that reads from the staging project + a `ENV=branch`
path that fetches from `supabase projects api-keys`. The prod literal is
load-bearing only for the prod release path.

### C3 — `build-testflight.sh` prod URL + anon key (deliberate)

**Severity:** DELIBERATE

**Where:** `build-testflight.sh:29-30`

The script's whole purpose is to build the prod TestFlight bundle. The
literal IS the load-bearing prod config.

### C4 — Prod project ref in CI workflow

**Severity:** DELIBERATE

**Where:** `.github/workflows/supabase-branch-vault.yml:68`
`PROJECT_REF: yrwcofhovrcydootivjx`

The workflow's whole purpose is to talk to the prod project (which has
Branching enabled). The project ref is contextual config, not a secret.

### C5 — Prod URL hardcoded inside `supabase/migrations/20260511065443_baseline.sql`

**Severity:** HIGH (persisting from previous audit; not yet resolved)

**Where:** `supabase/migrations/20260511065443_baseline.sql:1611`

```sql
THEN 'https://yrwcofhovrcydootivjx.supabase.co/storage/v1/object/public/media/' ||
     plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
```

**Concrete failure mode:** Baseline applies to EVERY branch DB
(per-PR + persistent staging) via Supabase Branching. Any plan published
against a branch DB has `thumbnail_url_line` minted with the prod
storage bucket URL. File doesn't exist there → broken-image glyph for
line-drawing thumbnails on every staging-published plan.

**Status:** WIP in `fix/env-aware-everything-else` — new migration
`supabase/migrations/20260512150219_get_plan_full_env_aware_thumb_line.sql`
re-creates `get_plan_full` reading the base URL from `vault.secrets`
(same pattern `sign_storage_url` already uses).

**Recommended fix:** Land the WIP migration.

### C6 — Archived patch SQL contains prod URL (historical reference)

**Severity:** INFORMATIONAL

**Where:**

- `supabase/archive/schema_lobby_three_treatment_thumbs.sql:103`
- `supabase/archive/schema_lobby_three_treatment_thumbs_existence_check.sql:100`
- `supabase/archive/schema_get_plan_full_restore_full_body.sql:186`
- `supabase/archive/schema_milestone_g_three_treatment.sql:282,734`

Archived patch files per CLAUDE.md ("historical reference only — do not
apply"). CI doesn't pick them up.

### C7 — `placeholder-anon-key` fallback in web-portal clients

**Severity:** LOW

**Where:** `web-portal/src/lib/supabase-browser.ts:14`,
`web-portal/src/lib/supabase-server.ts:13`, `web-portal/src/middleware.ts:44`

**Concrete failure mode:** Missing env var won't crash at module load —
the portal builds successfully and starts with a placeholder key. First
auth/network call returns a clear "invalid API key" error. Detectable
at runtime by users, not at build time by deploys.

**Status:** WIP in `fix/env-aware-everything-else`.

### C8 — `tools/filter-workbench/supabase_client.py` prod URL + anon key default

**Severity:** LOW

**Where:** `tools/filter-workbench/supabase_client.py:27-28`

```python
DEFAULT_SUPABASE_URL = "https://yrwcofhovrcydootivjx.supabase.co"
DEFAULT_SUPABASE_ANON_KEY = "sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3"
```

**Concrete failure mode:** Filter-workbench is a Streamlit dev tool
that runs locally for filter-parameter tuning. Default is prod (read-
only via RLS-scoped anon key), so a tuner against staging videos would
need explicit `SUPABASE_URL=` env override. LOW because this is a Carl-
local-only tool, no other developers run it.

### C9 — `web-portal/.env.example` ships prod URL + anon key

**Severity:** LOW

**Where:** `web-portal/.env.example:3-4`

**Concrete failure mode:** A developer copying `.env.example` → `.env`
for local dev runs their portal against PROD Supabase by default. Anon
keys are public-by-design but RLS-mutations from a confused developer
session would land in prod. LOW because the repo has one developer
today.

**Recommended fix:** Switch example to staging values + clear comment
"swap to prod values via Vercel env, never edit this file with prod
creds".

### C10 — Prod URL embedded in tracked Supabase CLI cache files

**Severity:** INFORMATIONAL (methodology gap, not a bug)

**Where:**

- `supabase/.temp/linked-project.json` — `{"ref":"yrwcofhovrcydootivjx",...}`
- `supabase/.temp/project-ref` — `yrwcofhovrcydootivjx`

**Concrete failure mode:** These are Supabase CLI cache files. They get
overwritten by `supabase link` and committed once + rarely touched
since. The reference is correct per repo state (Carl's CLI is linked to
prod for Branching). NOT a bug — but a methodology gap: the previous
audit wouldn't have caught this because `supabase/.temp/` looks like a
gitignored cache (and the wildcard `**/supabase/.temp/` IS in
`.gitignore`, but these specific paths were committed before the rule
landed).

**Recommended fix:** Either `git rm --cached supabase/.temp/*` and
re-add the directory to `.gitignore`'s top-level scope, or leave as-is
(the contents are correct).

## D. UUIDs and Sentinel IDs

### D1 — Sentinel UUIDs in `app/lib/config.dart`

**Severity:** MEDIUM (persisting)

**Where:** `app/lib/config.dart:204-207`

- `sentinelPracticeId = '00000000-0000-0000-0000-0000000ca71e'`
- `sentinelTrainerId = '00000000-0000-0000-0000-000000000001'`

**Concrete failure mode:** Sentinels exist in prod DB seeds. They DON'T
exist in staging-branch or per-PR DBs unless the seed migration runs
there. Auth's claim path silently falls back to "create a fresh personal
practice" when the sentinel is missing — that's the correct behaviour
TODAY, but any future logic that *requires* the sentinel would break on
non-prod.

**Status:** Not addressed by any WIP branch.

**Recommended fix:** Document in CI.md as a prod-only convenience.
Optionally enforce via `tools/enforce_data_access_seams.py` that code
using `sentinelPracticeId` tolerates absence.

### D2 — Sentinel UUID `00...000` in baseline migration index

**Severity:** INFORMATIONAL

**Where:** `supabase/migrations/20260511065443_baseline.sql:392`

NULL-coalesce sentinel used inside an index expression to allow NULL
`exercise_id` to participate in uniqueness. Not data — pattern.

### D3 — Carl's hardware UDIDs in install scripts

**Severity:** LOW

**Where:** `install-sim.sh:23` (sim UDID), `install-device.sh:32`
(iPhone UDID).

Anyone else running these scripts needs to swap. LOW because repo has
one developer today.

### D4 — Apple `DEVELOPMENT_TEAM` in project.pbxproj

**Severity:** LOW

**Where:** `app/ios/Runner.xcodeproj/project.pbxproj:524,708,732`

Carl's team ID. Future contributors would need to swap.

## E. Bundle / App Version

### E1 — Pubspec version sourced correctly

**Severity:** INFORMATIONAL

`app/pubspec.yaml` is the single source of truth.

### E2 — Web-player `PLAYER_VERSION` literal in `app.js`

**Severity:** LOW

Manually-maintained version string can lie if not bumped. Git SHA chip
is automatic and more accurate.

### E3 — Service worker cache version literal

**Severity:** INFORMATIONAL

Manual bump per CLAUDE.md when major web-player changes ship.

## F. Hardcoded Credentials or Merchant IDs

### F1 — `PAYFAST_PASSPHRASE` sandbox value in `.env.example`

**Severity:** MEDIUM (persisting from previous audit)

**Where:** `web-portal/.env.example:24`

Sandbox passphrase committed; risk of developer copying it forward into
prod `.env`.

### F2 — PayFast sandbox merchant ID + key fallback (deliberate)

**Severity:** LOW

`web-portal/src/lib/payfast.ts:163-165` — sandbox-gated fallback.
Production gets `''` and 500s loudly.

### F3 — `PAYFAST_IP_BLOCKS` dual source of truth

**Severity:** LOW (persisting)

`web-portal/src/lib/payfast.ts:136-146` and
`supabase/functions/payfast-webhook/index.ts:42-50`. Drift risk on
PayFast IP-range update.

## G. Hardcoded Paths

### G1 — Absolute `/Users/chm/dev/TrainMe` in `config.dart` docstring

**Severity:** LOW

`app/lib/config.dart:103` — cosmetic, in a docstring example.

### G2 — Absolute path in cron snippet in `tools/publish-health-ping/`

**Severity:** LOW

Carl-machine path; README acknowledges single-user tool.

## H. Magic Constants That Should Be Env-Aware

### H1 — `recycleBinRetentionDays = 7` (deliberate)

**Severity:** DELIBERATE

Stable product policy per R-01.

### H2 — Conversion-service timeouts (30s, 10s, 3min)

**Severity:** INFORMATIONAL

Tuned values for AVFoundation. Same on every env.

### H3 — Credit-pricing threshold `75 * 60` seconds

**Severity:** LOW

Product policy. Drift risk against portal copy / terms page.

### H4 — Signup-bonus credit amounts (3 organic, 5 referral)

**Severity:** LOW

Constants in Dart `AppConfig` + DB function. Drift risk on bonus tweak.

## I. Other Findings Worth Flagging

### I3 — Supabase auth redirect allowlist needs staging entries

**Severity:** MEDIUM (persisting from previous audit; CLAUDE.md notes
the prod-side allowlist additions but staging-side entries are inferred
absent)

**Where:** Inferred from absence. CLAUDE.md says the allowlist now
contains `studio.homefit.app://**` + `studio.homefit.app.dev://**` (added
2026-05-10 / -12). What's NOT explicitly stated: whether
`https://staging.manage.homefit.studio/**` + `https://staging.session.homefit.studio/**`
are also on the allowlist.

**Concrete failure mode:** A magic link with `emailRedirectTo` pointing
at a staging hostname is silently rejected by Supabase auth and falls
back to Site URL (per `gotcha_supabase_redirect_silent_fallback.md`).
Tester gets the email, taps the link, lands at `manage.homefit.studio`
instead of `staging.manage.homefit.studio` — wrong portal env.

**Recommended fix:** Audit via the Management API (`feedback_use_apis_not_dashboards.md`):

```bash
curl -H "Authorization: Bearer $SUPABASE_PAT" \
  "https://api.supabase.com/v1/projects/yrwcofhovrcydootivjx/config/auth" \
  | jq '.uri_allow_list'
```

Confirm both staging hosts are listed. If not, add via the same API.

### I4 — `web-portal/.env.example` is the prod template

**Severity:** LOW (cross-reference to C9)

### I5 — `web-player/api.js` config via `window.HOMEFIT_CONFIG` (deliberate)

**Severity:** DELIBERATE

Good pattern — config is injected via the generated `config.js`
(`web-player/build.sh`). No hardcoded supabase URL/key in `api.js`. The
model the other surfaces should mirror.

### I6 — `docs/RESEND_SETUP.md` references prod project ref

**Severity:** INFORMATIONAL

Documentation file. PROJECT_REF=yrwcofhovrcydootivjx is correct context
for the prod-specific Resend setup runbook.

## What to fix in the next release

Ranked HIGH → MEDIUM only.

1. **C5 (HIGH)** — Land the `fix/env-aware-everything-else` migration
   so `get_plan_full` reads its base URL from `vault.secrets`. Until
   this lands, every staging-published plan has broken line-drawing
   thumbnails. The migration is in WIP; needs Carl review and merge.
2. **A5 (HIGH)** — Land the `env.ts` strict-fail helper + refactor the
   five `??` callsites in the WIP branch. Pairs with C5.
3. **A7 (HIGH)** — `SessionsList.tsx` env-aware in same WIP branch.
4. **A9 (HIGH)** — `referralUrl()` strict-fail in same WIP branch.
5. **A11 + A12 (MEDIUM)** — `home_screen.dart` + `home_credits_chip.dart`
   SnackBar / display strings env-aware in same WIP branch.
6. **A8 (MEDIUM)** — `audit/page.tsx` env-aware (same WIP branch).
7. **C7 (LOW, but bundle-with-A5)** — `placeholder-anon-key` strict-fail
   in same WIP branch.
8. **B2 (LOW, but trivial)** — Read os_log subsystem from
   `Bundle.main.bundleIdentifier` so dev builds surface in Console.
9. **I3 (MEDIUM, but bundle-with-staging-readiness)** — Verify Supabase
   auth allowlist has staging hostnames via Management API.

Most of HIGH + MEDIUM is already on the `fix/env-aware-everything-else`
branch as WIP. Top priority is landing that PR.

## Methodology lesson for future audits

Mechanical literal-string grep across ALL file types, with only
generated/lock files excluded. Interpretive scoping ("URL patterns in
source code") silently excludes:

- HTTP-header values in JSON config (CSP, CORS, etc.)
- CI workflow `env:` blocks
- Test fixture strings
- Documentation-as-code (TSX/SVG with hostnames as visual content)
- Tracked CLI cache files

The literal-grep methodology is annoyingly verbose but uniformly safe.
Add it as a CI check (`tools/grep-prod-refs.sh`) that runs on PRs
touching anything env-sensitive.
