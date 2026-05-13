# Checkpoint — 2026-05-13 — Env-aware hardening + TestFlight v2 prep

**Two-day arc landing TestFlight v2 readiness:** the release-train pipeline (cutover 2026-05-11) had landed but real CI/CD bugs lurked — the previous day's staging QA wave (2026-05-12) discovered seven hardcoded prod URLs across mobile + web-portal + web-player + Vercel CSP that broke staging-routed builds in subtle ways. This checkpoint covers the morning batch of 2026-05-13 that closed those out + landed three small functional/UX fixes from staging-QA feedback, plus a cloud-session-produced home-shell scope refactor (PR #315). End-state: staging is fully exercised end-to-end on mobile + web; iPhone CHM is installed and Carl is mid-QA when this checkpoint is written.

## Table of Contents

- [Status](#status)
- [What landed today (2026-05-13)](#what-landed-today-2026-05-13)
- [What landed yesterday for context (2026-05-12)](#what-landed-yesterday-for-context-2026-05-12)
- [Carl's outstanding QA — test items 1-10](#carls-outstanding-qa--test-items-1-10)
- [Stacked but not yet implemented](#stacked-but-not-yet-implemented)
- [TestFlight v2 playbook](#testflight-v2-playbook)
- [Gotchas + memory rules surfaced this session](#gotchas--memory-rules-surfaced-this-session)
- [Fresh-session handoff](#fresh-session-handoff)

## Status

- **Where main is:** still at `b5f9a1d` (the 2026-05-12 re-audit doc). Nothing has been promoted today. Per Carl's rule "nothing to main without staging QA first."
- **Where staging is:** `84d0bcc` — Merge PR [#315](https://github.com/carlheinmostert/TrainMe/pull/315). Includes everything from #304-#315 + #314 (test-script index update).
- **Where Carl's iPhone CHM is:** installed at staging tip `84d0bcc` via `./install-device.sh staging` (full clean rebuild because dart-defines fingerprint changed — OpenCV rebuilds via dartcv4 took ~10 min).
- **Vercel staging surfaces:**
  - `staging.session.homefit.studio` ✓ live, serves web player with `CACHE_NAME = homefit-player-<7-char-sha>` auto-bumped per deploy (PR #310)
  - `staging.manage.homefit.studio` ✓ live, serves web portal with new `/help/credits` route (PR #311)
- **Supabase:** staging branch `vadjvkmldtoeyspyoqbx` has all migrations applied via Branching workflow + the directly-applied C5 thumbnail fix from 2026-05-12 (idempotent on next branch sync).
- **Blocked on Carl (unchanged):** Hostinger 301s · `support@homefit.studio` mailbox · ZA lawyer · PayFast prod merchant.

## What landed today (2026-05-13)

**Six PRs against staging — three small UX/hygiene fixes from yesterday's QA feedback + one from a parallel cloud session + one batch test-script index update.**

| PR | Title | Why |
|---|---|---|
| [#310](https://github.com/carlheinmostert/TrainMe/pull/310) | `chore(web-player): inject git SHA into SW cache name — auto-bust on every deploy` | Yesterday Carl manually unregistered SW twice (~30 min lost) after CSP fix shipped because `homefit-player-v75` cache name didn't change. `build.sh` now rewrites a `__BUILD_SHA__` sentinel in `sw.js` to the 7-char deploy SHA. |
| [#311](https://github.com/carlheinmostert/TrainMe/pull/311) | `feat: out-of-credits chip redesign + /help/credits article (Reader-App compliant)` | Verbose plain-text "you're out of credits, top up at manage..." didn't fit Home AppBar. Replaced with filled-coral pill (`0 ?` + 280ms fade-in) that opens `staging.manage.homefit.studio/help/credits` via Safari View Controller. Help page is informational only — no Buy CTA, no prices (Apple Guideline 3.1.1 / Reader-App). |
| [#312](https://github.com/carlheinmostert/TrainMe/pull/312) | `fix(embedded-preview): exempt 'plan' host from api.js strict-fail check` | Yesterday-morning bug: mobile workflow Preview step (embedded web player via Swift `UnifiedPlayerSchemeHandler`) showed "No internet connection". Root cause: commit `2cda208` (2026-05-11) added a strict-fail IIFE guard at `web-player/api.js:113` that threw if `window.HOMEFIT_CONFIG` was missing AND host wasn't in a loopback exception list. The list missed `'plan'` (the custom-scheme host). 1-line fix. |
| [#313](https://github.com/carlheinmostert/TrainMe/pull/313) | `feat: auto-open consent on first client entry + filmstrip refresh on session exit` | Two coupled fixes. **(a)** Capture defaults to B&W but if `client.video_consent.grayscale` isn't granted, playback silently fails. Added `clients.consent_explicitly_set_at TIMESTAMPTZ` column (NULL = never touched) — mobile auto-expands consent accordion on first entry. **(b)** Session card filmstrip (4 hero frames) was stale when new exercises captured. `ClientSessionsScreen` now subscribes to `ConversionService.onConversionUpdate` and reloads. Includes SQL migration `20260513065845_consent_explicitly_set_at.sql` (column + `set_client_video_consent` stamps + RPC re-creates with column-preservation). |
| [#314](https://github.com/carlheinmostert/TrainMe/pull/314) | `docs(test): batch index update — 4 new test waves from 2026-05-13 morning batch` | Docs-only: index entries for the 4 new test scripts. Renumber 60 → 64. |
| [#315](https://github.com/carlheinmostert/TrainMe/pull/315) | `home: two-capsule scope shell + My Workouts teaser + lobby import stub` | Created in a parallel cloud session yesterday. Front-end app shell for TestFlight v2 — locks the IA shape: `[Clients · Classes Soon] [My Workouts Soon]` two-capsule layout on Home. Workouts is a placeholder body with mock cards; backend wiring deferred to a follow-up. Web-player lobby gets a "Get the app & import this session" CTA with a no-op submit. Rebased + force-pushed onto staging (sw.js conflict resolved — kept #310's auto-bump, dropped #315's manual v77 bump). |

## What landed yesterday for context (2026-05-12)

The CI/CD env-aware hardening wave that produced the bugs #310-#313 fixed today. Quick recap so a fresh session can navigate:

| PR | Title | Status |
|---|---|---|
| [#304](https://github.com/carlheinmostert/TrainMe/pull/304) | env-aware share URLs + portal origin + edge-swipe overlay + password errors + OAuth redirect | merged 2026-05-12 |
| [#305](https://github.com/carlheinmostert/TrainMe/pull/305) | install-device.sh auto-clean when dart-defines change | merged 2026-05-12 |
| [#307](https://github.com/carlheinmostert/TrainMe/pull/307) | CSP wildcard + middleware env-aware | merged 2026-05-12 |
| [#308](https://github.com/carlheinmostert/TrainMe/pull/308) | env-aware everything-else (A5/A7/A8/A9/A11/A12/C5/C7) | merged 2026-05-12 |
| [#309](https://github.com/carlheinmostert/TrainMe/pull/309) | capture defaults → B&W + body-focus-off (sticky still wins) | merged 2026-05-12 |
| [#306](https://github.com/carlheinmostert/TrainMe/pull/306) | superseded by #307 | closed |

**The hardcoded-values audit doc** is at [`docs/HARDCODED-AUDIT-2026-05-12.md`](HARDCODED-AUDIT-2026-05-12.md). The re-audit at commit `b5f9a1d` is mechanical-grep methodology (previous methodology missed the vercel.json CSP, the load-bearing miss).

## Carl's outstanding QA — test items 1-10

Carl was mid-QA when this checkpoint was written. The current install on iPhone CHM is `studio.homefit.app.dev` (separate icon from TestFlight v1 `studio.homefit.app`). Open the **`.dev`** icon.

1. **Build SHA marker** — Settings reads `84d0bcc`.
2. **Capture default check** — fresh client → consent sheet auto-opens expanded (NEW from #313).
3. **Consent persistence** — toggle consent → close → re-enter → sheet does NOT re-open.
4. **Legacy client** — existing client whose consent was never set → first entry → sheet auto-opens.
5. **Filmstrip refresh** — open a session → capture a new exercise → exit → session card filmstrip shows the new hero.
6. **Out-of-credits chip** — practice with 0 credits → Home AppBar shows filled coral pill with `0 ?` (NEW from #311).
7. **Help article** — tap `?` on the coral pill → Safari View Controller opens `staging.manage.homefit.studio/help/credits` (informational only, no Buy).
8. **Embedded preview** — workflow Preview on a published plan → web player loads (no "No internet").
9. **Home scope shell** — Home AppBar shows two-capsule scope (Clients · Classes Soon | My Workouts Soon) (NEW from #315).
10. **Lobby import stub** — staging.session.* web player → bottom of lobby → "Get the app & import this session" → email sheet → submit shows "Thanks!" toast.

**Each test script is linked from `docs/test-scripts/index.html` entries 1-4.** Local docs server at `http://localhost:3457` serves them with pass/fail tracking.

## Stacked but not yet implemented

Carl said "stack them until I've gone through all the things" during today's QA. These are queued for next session:

1. **The "auto-clean only when dart-defines change" optimization (#305) doesn't pay off** — `GIT_SHA` is one of the fingerprint inputs and changes every commit, so every install does a full clean → OpenCV rebuilds (10-15 min). Options: exclude `GIT_SHA` from the fingerprint, or cache OpenCV artifacts outside `app/build/`, or detect SHA-only delta and skip clean. Pick after weighing risk of stale GIT_SHA in built binary.
2. **Mid-QA finding from item 5 on yesterday's install** — Carl reported the "Embedded workflow Preview 'No internet'" bug. Fix landed in #312, but Carl's verification on the new build is pending.

## TestFlight v2 playbook

Carl explicitly asked to discuss TestFlight only **after** all staging QA passes. Once items 1-10 pass:

1. `git checkout main && git pull --ff-only origin main`
2. `gh pr create --base main --head staging --title "Release: 2026-05-13 — TestFlight v2 readiness — env-aware hardening + capture defaults + UX fixes"`
3. Wait ~10s for `release-notes.yml` to comment migration list. Read it (one new C5 migration since main: `20260512150219_get_plan_full_env_aware_thumb_line.sql` + `20260513065845_consent_explicitly_set_at.sql`).
4. **Merge with "Create a merge commit"** (NOT squash — `release-tag.yml` only fires on `Merge pull request` subject prefix). Watch for `v2026-05-13.1` tag (or `.N` if other tags landed today).
5. `git checkout main && git pull --ff-only`
6. `./bump-version.sh build` — bumps build number, commits, tags `mobile-v1.0.0+2` (or next).
7. `./build-testflight.sh` — produces `app/build/ios/ipa/Runner.ipa`.
8. Upload via Transporter or `xcrun altool --upload-app -f app/build/ios/ipa/Runner.ipa -t ios -u <apple-id> -p <app-specific-password>`.

**Built into TestFlight v2 vs v1 (`f6f7bce`, 2026-05-05):**
- Camera back-nav fix (#303)
- Editor sheet thumb-reach (#288)
- Swift hardening + OAuth env-aware redirect (#287, #304)
- Env-aware URLs / portal origin / share URLs / password reauth fix
- iOS edge-swipe overlay
- Auto-clean install-device + SW cache auto-bump
- Out-of-credits chip + /help/credits article
- Embedded preview "No internet" fix
- Consent auto-open on first entry
- Session card filmstrip refresh
- Home scope shell (Clients · Classes Soon | My Workouts Soon) + lobby import stub

## Gotchas + memory rules surfaced this session

**New gotchas worth memorizing in `~/.claude/projects/-Users-chm-dev-TrainMe/memory/`:**

1. **Supabase Branching doesn't clone three things**:
   - **Storage buckets + policies** — created manually on prod, missing on every branch. Need to mirror via SQL (read from prod, replay on branch) on every fresh staging setup.
   - **Vault secrets** — `supabase_url` + `supabase_jwt_secret` for `sign_storage_url` to work. Staging had them populated 2026-05-11; future fresh branches won't.
   - **`auth.users`** — fresh branch creates fresh auth identities. Practitioners signing in to staging via magic link get NEW user IDs that don't match `practice_members` rows cloned from prod → see empty client lists. This is correct behaviour (isolation) but worth knowing.

2. **Apple Reader-App compliance** allows informational help articles linked from in-app via Safari View Controller — but the help article itself must NOT have Buy / Purchase / pricing CTAs. The `/help/credits` page at `manage.homefit.studio/help/credits` is the reference pattern. (PR #311.)

3. **Service worker cache name** is now auto-bumped per deploy via the `__BUILD_SHA__` sentinel in `web-player/sw.js` rewritten by `build.sh`. No more manual cache-name version bumps needed. The cache eats stale HTML headers (including CSP) until the name changes — caused two real outages on 2026-05-12.

4. **DNS for Hostinger CNAMEs must match Vercel's current CNAME target**, not the older generic `cname.vercel-dns.com`. Update via Hostinger hPanel → DNS Zone → CNAME for `staging.session` and `staging.manage` should both point at `00596c638d4cefd8.vercel-dns-017.com.` (the homefit-web-player project's specific target — Vercel reuses it across projects in the new IP range).

5. **macOS DNS cache flush** is needed after Hostinger DNS changes: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`. Browsers don't always pick up resolver changes without this.

6. **NordVPN can blackhole specific Vercel IP ranges** even when DNS resolves correctly. If a URL fails for Carl but works for the agent's Mac, NordVPN-off is the first thing to try.

## Fresh-session handoff

**Read this checkpoint first.** Then:

- **CLAUDE.md** at repo root has the project overview + invariant rules.
- **`docs/HARDCODED-AUDIT-2026-05-12.md`** has 51 audit findings, 4 active HIGH severities still queued (web-portal middleware fallback, SessionsList hardcoded URL, referral-share fallback, embedded preview — actually #312 closed the last).
- **`docs/CI.md`** has the release-train architecture.
- **`docs/test-scripts/index.html`** at `http://localhost:3457` has the QA scripts.

The user is `Carl` — practitioner-product owner. Memory rules in `~/.claude/projects/-Users-chm-dev-TrainMe/memory/` apply automatically. Key invariants:

- **Specs/docs go direct to main**, no PR (per `feedback_specs_direct_to_main.md`).
- **Code goes through staging first** — no main promotion without staging QA pass.
- **Branch naming**: `feat/`, `fix/`, `chore/`, `docs/` — ask Carl at task start if uncertain.
- **Don't auto-promote staging→main** — Carl explicitly drives that step.
- **Use Vercel/Supabase CLI + Management API**, not dashboards (per `feedback_use_apis_not_dashboards.md`).
- **No direct DB access** — all reads/writes via the per-surface access layer's enumerated RPCs (per `feedback_no_direct_db_access.md`).
- **Delegate non-trivial coding to a sub-agent** — Carl prefers background agents over inline implementation.
- **Always create a test script** under `docs/test-scripts/` for every device-install wave.
- **Always end build/install messages with a numbered test list** scoped to what changed.

Current open question state — none. Carl is mid-QA on items 1-10. Next agent should:
1. Wait for Carl's QA results.
2. If pass → guide him through TestFlight v2 playbook (see above).
3. If fail → diagnose and fix on a focused branch; same release pattern.

End-state target for tomorrow: TestFlight v2 uploaded to App Store Connect, bundle `studio.homefit.app`, build `1.0.0+2` (or next available).
