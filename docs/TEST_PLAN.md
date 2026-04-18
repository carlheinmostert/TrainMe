# homefit.studio — Test Plan

**Owner:** Carl (product), QE agent (plan author)
**Status:** Draft for review — no test code written yet
**Living doc:** Update this file when any gate, tool, or phase changes. PRs that change the plan require Carl's review.
**Last updated:** 2026-04-18

---

## 0. Philosophy

- **Prevent, don't detect.** The tests that matter most run before code reaches main, not after Melissa finds a bug.
- **Risk-weighted.** We have ~14 days to MVP. We test the 20% of surfaces that cause 80% of impact: publish flow, credit ledger, RLS, PayFast webhook, Studio layout.
- **Every bug gets a test.** The recent code review surfaced real defects (publish ordering, client-side refund INSERT, silent bootstrap failure, `_loadSessions` no try/catch). Each one lands with a regression test named after it. No exceptions.
- **Goldens for layout, contracts for boundaries, property tests for invariants.** Plain example-based tests for the rest.
- **Tests live with the code.** No separate "QA repo". Flutter tests under `app/test/`, portal under `web-portal/tests/`, Supabase under `supabase/tests/`, web player under `web-player/tests/`.

---

## 1. Test Pyramid Strategy

Target split per surface. Percentages are rough guidance, not hard budgets.

### Flutter app (`app/`)
- **Unit** — 50%. Services, models, utilities, path resolution, credit-cost math, circuit unrolling, conversion queue state machine. Fast. No widget tree, no platform channels.
- **Widget** — 30%. Screens in isolation with mocked services. Sign-in states, home-list empty/error, Studio gutter rail, inline action tray, progress-pill matrix, undo snackbar.
- **Golden** — 10%. Studio with 0/1/N circuits (the live bug), progress-pill matrix at three tiers, sign-in states. Separate from the widget %% because goldens are slower and need their own CI tier.
- **Integration (on-device / simulator)** — 10%. End-to-end critical paths: capture-to-publish, sign-in sentinel claim, offline degradation. Runs less often (nightly + pre-TestFlight).

Justification: Flutter unit tests are the cheapest, and most of our logic bugs (credit-cost math, ordering, path resolution, circuit flattening) are unit-testable. Widget and golden tests guard the UI surfaces that Carl demos to Melissa. Integration tests are expensive on iOS (~minutes each) so we reserve them for irreplaceable end-to-end paths.

### Web player (`web-player/`)
- **Unit (Vitest)** — 60%. `app.js` logic: circuit unrolling, rest consolidation, slide state machine, progress-pill calculation, ETA math, service worker cache policy.
- **Component/DOM (Vitest + happy-dom)** — 20%. Slide deck rendering, keyboard nav, pause/play transitions.
- **E2E (Playwright)** — 20%. Full plan load via stubbed `get_plan_full`, WhatsApp OG middleware, service-worker offline replay.

Justification: the web player is small enough that most bugs are in pure logic, and Vitest + happy-dom gives us 95% of what a browser harness would at 10% the cost.

### Web portal (`web-portal/`)
- **Unit (Vitest + RTL)** — 40%. Credit-balance components, practice switcher, audit-table rendering, PayFast-return page state.
- **Integration (Vitest + msw)** — 40%. Supabase client mocking, server-action correctness, checkout intent creation, redirect flows.
- **E2E (Playwright)** — 20%. Full sign-in → dashboard → credits → PayFast redirect round-trip (against sandbox).

Justification: Next.js App Router with server components makes RTL-only testing incomplete — we need Playwright for real server-rendered pages and cookie-based auth.

### Supabase (`supabase/`)
- **SQL (pgTAP)** — 70%. RLS policies, `consume_credit` atomicity, `get_plan_full` payload, helper fns, schema constraints.
- **Edge Function (Deno.test)** — 30%. `payfast-webhook` — signature verification, all four gates, replay, IP rotation, idempotency.

Justification: the data layer is where the money lives (credit ledger). pgTAP is the only tool that asserts RLS from multiple JWTs in the same test. Deno.test is native to Edge Functions and needs no scaffolding.

### Cross-cutting
- **RPC contract tests** — 5-10 tests. Generated fixtures (canonical plan shapes, canonical ledger rows) asserted by Dart, JS, and SQL sides consume them identically. See section 3g.

---

## 2. Tech Stack Recommendations

Per surface, opinionated picks.

### Flutter
| Tool | Purpose | Tradeoff |
|---|---|---|
| `flutter_test` (built-in) | Unit + widget | Default; no alternative |
| `mocktail` | Mocking | Null-safe, no codegen — faster iteration than mockito for a small team |
| `integration_test` (built-in) | On-device E2E | Works out of the box on simulator + device; enough for MVP |
| `alchemist` | Golden tests | Cross-platform stability (renders goldens on a headless engine, not the OS surface) vs `golden_toolkit` which drifts between iOS versions |
| `patrol` | Native iOS interactions (camera, share sheet, permissions) | Superset of `integration_test`; only pull in if we hit a case `integration_test` can't express — otherwise adds native-build friction |
| `very_good_coverage` | Line-coverage gate on CI | Lightweight; plugs straight into Flutter's `--coverage` output |

**Recommendation: start with `flutter_test + mocktail + alchemist + integration_test`. Defer `patrol` until we have a concrete flow it's needed for (likely camera permission paths).**

### Web player
| Tool | Purpose | Tradeoff |
|---|---|---|
| `vitest` | Unit + component | Faster than Jest, first-class ESM, matches web-portal stack |
| `happy-dom` | DOM emulation | Lighter than jsdom, enough for our widget tests |
| `playwright` | E2E + service-worker | Real Chromium; supports `serviceWorker.register` in tests, which jsdom can't |
| `msw` | Fetch/Supabase stubbing | Same request-interception model across Vitest and Playwright |

### Web portal
| Tool | Purpose | Tradeoff |
|---|---|---|
| `vitest` + `@testing-library/react` | Unit + component | Standard Next.js pairing |
| `msw` | Supabase + PayFast stubbing | Same as web-player, shares fixtures |
| `playwright` | E2E + auth cookies | Handles Supabase SSR cookie dance that RTL cannot |
| `@supabase/ssr` test helpers | Auth scenarios | Bundled with the lib; avoids hand-rolling cookie state |

### Supabase
| Tool | Purpose | Tradeoff |
|---|---|---|
| `pgTAP` | SQL assertions, RLS, RPC behaviour | The only serious option for policy testing; installs as a Postgres extension |
| `supabase db test` (CLI wrapper) | Runner for pgTAP against the linked project or a local ephemeral db | Native; no extra harness |
| `deno test` | Edge Function tests | Native to Deno, no third-party runner needed |
| `mockttp` (or hand-rolled `Deno.serve` stub) | PayFast ITN validation-server stub | `mockttp` is overkill for two endpoints — a `Deno.serve` fixture is fine |

### Cross-cutting
| Tool | Purpose |
|---|---|
| Canonical JSON fixtures in `test-fixtures/` (top of repo) | Consumed by Dart, JS, and SQL-loader tests. Prevents `get_plan_full` drift |
| `schemars`-free approach: hand-write the RPC contract in `docs/rpc-contract.md`, enforce via fixtures + round-trip tests | Full codegen buys little for 4 RPCs |

---

## 3. Critical-Path Test Inventory

Everything below MUST be green before MVP ship (2026-05-02). Grouped by domain, each line is `scenario — layer that owns it`.

### a. Auth & tenancy
1. First-ever sign-in claims Carl-sentinel practice — **integration (app)** against staging db.
2. Second-ever sign-in auto-creates personal practice (not the sentinel) — **integration (app)**.
3. Bootstrap failure after successful sign-in surfaces a user-visible error (not silent) — **widget (app, `auth_gate.dart`)**. *Regression from code review.*
4. Magic-link path when password is blank — **widget (`sign_in_screen.dart`)**.
5. Magic-link fallback when `signInWithPassword` returns invalid-credentials — **widget**.
6. "Set a password?" banner appears once, dismissal persists — **unit (`shared_preferences` wrapper)** + **widget**.
7. `user_practice_ids()` returns only memberships of the calling JWT — **pgTAP**.
8. `user_is_practice_owner(pid)` rejects non-member — **pgTAP**.
9. RLS on `practice_members` does not recurse (the fix-it-once trap) — **pgTAP** with EXPLAIN-based assertion that no row-level subquery touches `practice_members` directly.
10. Multi-practice practitioner sees correct practice in the publish picker — **widget + integration**.

### b. Publish flow
11. **Happy path:** pre-flight → `consume_credit` → `plans.upsert` → media upload → exercises upsert → orphan cleanup → `plan_issuances` row — **integration (app) + pgTAP**.
12. **Ordering regression:** `consume_credit` MUST run before `plans.upsert` (version bump). If `consume_credit` fails, plan row is not bumped — **unit (`upload_service.dart`)** with a fake Supabase client; asserts call order. *From code review.*
13. Credit exhaustion returns a clean error, no partial writes — **integration**.
14. Media upload failure triggers compensating refund ledger row — **integration**.
15. Partial publish (some exercises uploaded, some failed) does not leave orphan storage objects — **integration**.
16. Idempotent re-publish of the same plan does not double-consume credits (we rely on plan_id+version key) — **pgTAP** + **integration**.
17. Plan URL stays stable across version bumps — **unit**.
18. Publish-screen practice picker (D2) consumes credits from the chosen practice, not the practitioner's default — **widget + integration**.

### c. Credit ledger
19. `consume_credit(...)` is atomic under concurrent callers (FOR UPDATE holds) — **pgTAP** with `BEGIN; ... ; COMMIT;` parallel sessions.
20. `practice_credit_balance` = sum(delta) and matches ledger — **pgTAP**.
21. Credit cost formula `ceil(non_rest_count / 8)` clamped to `[1, 3]` — **unit (Dart)** + **pgTAP**.
22. Non-owner practitioner CANNOT insert into `credit_ledger` from client — **pgTAP** with a practitioner JWT. *Blocks client-side refund mint.*
23. Non-member of a practice CANNOT SELECT its ledger rows — **pgTAP**.
24. Refund row is only ever written by `consume_credit`'s compensating path (SECURITY DEFINER) — **pgTAP** asserting INSERT policy rejects client.
25. Ledger is append-only — UPDATE and DELETE policies reject all JWTs — **pgTAP**.

### d. PayFast webhook
26. Valid ITN with correct signature credits the practice — **Deno.test** with signed fixture.
27. Wrong signature rejected 400 — **Deno.test**.
28. Bad source IP rejected 403 — **Deno.test**.
29. Validation-server `INVALID` response rejected — **Deno.test** with stubbed PayFast server.
30. Amount mismatch between `pending_payments` and ITN rejected — **Deno.test**.
31. Replay attack (duplicate `pf_payment_id`) rejected (idempotency) — **Deno.test** against a seeded db.
32. Webhook succeeds even if PayFast IP range rotates — **Deno.test** with a fresh IP; asserts IP list is sourced from a constant we can patch, not hard-coded.
33. `pending_payments` transitions: `pending → paid`, `pending → failed`, `pending → expired` — **pgTAP**.

### e. Studio editing (golden + behavioural)
34. 0 circuits, 3 exercises — **golden (app, `studio_mode_screen.dart`)** at iPhone 16e logical size.
35. 1 circuit with 3 exercises, cycles=2 — **golden**. *The layout bug.*
36. 2 non-adjacent circuits in one plan — **golden**.
37. Empty plan state — **golden**.
38. Reorder exercise inside a circuit — **widget** (asserts `position` + `circuitId` after drop).
39. Break circuit via Circuit Control Sheet fires undo snackbar — **widget**.
40. Thumbnail Peek long-press → delete → undo restores — **widget**.
41. Insert rest period via Circuit Control Sheet — **widget**.
42. Learned rest interval default (10 min) applied when no prior user drag behaviour — **unit**.
43. Inline action tray collapses when another card opens — **widget**.

### f. Web player
44. Anonymous load via `get_plan_full` renders all slides — **Playwright**.
45. Circuit unrolling: 1 circuit × 3 rounds = 3 rendered slide groups — **Vitest**.
46. Rest consolidation: rest card shows ONE timer chip, not two — **Vitest + DOM**.
47. Swipe/chevron/arrow skip cancels in-flight timer — **Vitest**.
48. Video on active slide auto-plays muted + looped — **Playwright**.
49. Pause overlay only after explicit user pause — **Vitest**.
50. Service worker serves cached app shell when offline — **Playwright** with offline emulation.
51. Service worker rejects non-video content-types (cache-poisoning guard) — **Vitest**.
52. WhatsApp OG middleware returns bot-friendly HTML for `User-Agent: WhatsApp/*` — **Playwright**.
53. Progress-pill matrix: idle/active/completed/rest states render correctly — **golden (Playwright screenshot)**.
54. ETA widget: `remaining` holds, `finish` drifts while paused — **Vitest**.

### g. Conversion pipeline
55. Happy path: photo → converted + thumbnail paths written to db — **integration (sim) + unit (ConversionService state machine)**.
56. Video path routes through native `VideoConverterChannel.swift` (asserted by the Dart side seeing the expected method signatures) — **unit + contract**.
57. FIFO queue resumes after app restart — **integration**.
58. HEVC fallback on simulator (skip-with-marker) — **integration** with a simulator-specific gate.
59. Raw archive written to `{Documents}/archive/{exerciseId}.mp4` within 90-day retention — **integration**.
60. Stale paths after reinstall resolve via `PathResolver` — **unit**.
61. OpenCV binding loads without segfault on a cold boot — **integration smoke**.

### h. RPC contract cross-cutting
62. `get_plan_full(uuid)` output matches `test-fixtures/plan.canonical.json` — **pgTAP** + **Dart unit** + **Vitest** all load the same fixture.
63. `consume_credit(practice_id, plan_id, credits)` signature stable — fixture-driven.

### i. Home screen resilience *(code-review regression)*
64. `_loadSessions` DB failure surfaces error state, no infinite spinner — **widget**.
65. Empty sessions list shows empty state, not spinner — **widget**.

### j. POPIA
66. Error logs never contain `clientName`, absolute video paths, or raw emails — **unit** (grep-style test over a logger fixture).
67. `media` bucket INSERT path-prefix policy rejects writes outside the caller's practice — **pgTAP**.

### k. Share sheet
68. `Share.share` includes `sharePositionOrigin` on iOS — **widget** (asserts the call is made with a non-null origin).

---

## 4. Golden / Visual Regression Strategy

### Where we need goldens
- Studio screen with 0/1/N circuits (the live bug surface).
- Web player progress-pill matrix at dense / medium / spacious.
- Web player slide states: idle / active / completed / rest.
- Sign-in form in all four states: idle / sending / sent / error.
- Empty / loading / error states on Home and Plan list.
- Inline Action Tray expanded + collapsed.

### Tooling
- **Flutter:** `alchemist`. It renders goldens against a synthetic engine (not the iOS surface), so goldens stay stable across iOS runner versions. `golden_toolkit` drifts between iOS 17 / 18 because it uses the real platform renderer — we've been bitten by this pattern before on other projects.
- **Web:** Playwright `toHaveScreenshot()` with a fixed viewport (390×844, iPhone 14 baseline) and `maxDiffPixelRatio: 0.001`. Darwin-only runners for consistent font rendering (see CI section).

### CI runner image policy
- Goldens run ONLY on `macos-14` (pinned). Drop upgrades land on a branch labeled `ci/macos-upgrade`, bless goldens once, merge.
- Flutter version pinned via `fvm` config checked in (`.fvmrc` or `flutter.version`). CI reads it.
- Web portal + web player Playwright runners use `mcr.microsoft.com/playwright:v1.XX.X-jammy` pinned.
- **Drift policy:** if a golden fails on an unrelated PR, we do not bless it in that PR. We open a follow-up PR titled `chore(goldens): bless <reason>` with the regen'd files, reviewed on its own.

### Golden file discipline
- Goldens live next to tests: `app/test/goldens/studio/*.png`, `web-player/tests/goldens/*.png`.
- They are committed to git (yes, binaries — worth it).
- CI uploads the diff PNG as an artefact on failure so Carl can eyeball instead of guessing.

---

## 5. Milestone Gating

What "passing" means at each gate. `Gate` = cannot proceed without these.

### Gate 1: Pre-merge to main (every PR)
- All unit + widget + SQL tests green.
- Goldens green OR a `chore(goldens)` follow-up PR linked in the description.
- Line coverage ≥ 70% on changed files (enforced via `very_good_coverage` + `codecov` patch check).
- `next lint` + `flutter analyze` clean.
- No new `TODO: test` lines without a linked issue.

### Gate 2: Pre-device-install (`install-device.sh`)
- Gate 1 green on the branch.
- Flutter integration tests green on iOS simulator (iPhone 16e).
- `supabase db test` green against a fresh local db seeded from `schema.sql + schema_milestone_*.sql`.

### Gate 3: Pre-TestFlight
- All of Gate 2 plus:
- Full integration suite green on both simulator (iPhone 16e) AND physical device (Carl's iPhone `00008150-001A31D40E88401C`) — nightly.
- Playwright E2E green against staging web portal + web player.
- PayFast webhook Deno tests green against sandbox creds.
- Manual smoke: sign in fresh account → capture 3 exercises → publish → open on web player → client-view renders.
- POPIA log-scrub test green.

### Gate 4: Pre-App-Store submission
- All of Gate 3 plus:
- 48h TestFlight burn-in with Carl + Melissa using the app daily, zero P0 bugs.
- All tests in section 3 checked off.
- `docs/PENDING_DEVICE_TESTS.md` empty.
- Golden coverage: every screen in `app/lib/screens/` has at least one golden.

### Gate 5: Pre-production-PayFast cutover
- Gate 4 green.
- PayFast webhook tests re-run against PRODUCTION creds in a staging sandbox first.
- Manual end-to-end: R5 test purchase → ITN received → credit ledger row → balance increments → refund test → ledger reflects.
- Replay attack test re-verified against production endpoint.
- Incident runbook in `docs/RUNBOOKS/payfast-incident.md` reviewed.

---

## 6. CI Integration

### Platform: GitHub Actions
We have no CI today. Start minimal, grow with need.

### Workflows to create
```
.github/workflows/
  flutter-ci.yml       # PR + push to main
  web-portal-ci.yml    # PR + push affecting web-portal/**
  web-player-ci.yml    # PR + push affecting web-player/**
  supabase-ci.yml      # PR + push affecting supabase/**
  integration-nightly.yml  # Cron 02:00 SAST, full suite
  goldens-weekly.yml   # Cron Sun 03:00, regens goldens, opens a PR if drift
```

### Triggers
- **PR:** run the workflow for the touched directory only (path filters). Don't run Flutter CI on a web-portal-only PR.
- **Push to main:** run all four CI workflows (safety net for crossed-wires commits).
- **Nightly:** full integration + goldens + Playwright + pgTAP against staging.
- **Manual dispatch:** `workflow_dispatch` on all for ad-hoc runs before device install.

### Matrix strategy (Flutter)
- Flutter version: pinned 3.41.6 (single cell — we don't multi-version until post-MVP).
- iOS simulator: iPhone 16e only for MVP. Adding iPhone 15 / iPad post-MVP when we expand device matrix.
- macOS runner: `macos-14` pinned.

### Caching (must-have for SA free-minute budget)
- Pub cache: `~/.pub-cache` keyed on `pubspec.lock`.
- CocoaPods: `app/ios/Pods` + `~/Library/Caches/CocoaPods` keyed on `Podfile.lock`.
- Xcode DerivedData: `~/Library/Developer/Xcode/DerivedData` keyed on `Podfile.lock + pubspec.lock + os`.
- `node_modules` for portal + player: keyed on `package-lock.json`.
- Playwright browsers: `~/.cache/ms-playwright` keyed on Playwright version.
- Supabase local db: skipped (docker pull is faster than cache restore).

### Artefacts
- Golden-diff PNGs on failure (retention 14 days).
- `flutter build ios --release` .app bundle on tags matching `v*` for TestFlight (retention 90 days).
- `coverage/lcov.info` + codecov upload (retention 30 days).
- Playwright HTML report + traces on failure (retention 14 days).

### Cost control
- macOS minutes are 10x Linux. Run golden + integration on macOS, everything else on Linux (pgTAP runs in a Postgres docker container on Linux; web tests run on Linux Playwright).
- PR runs: path-filter ruthlessly. A docs-only PR runs nothing.
- Nightly runs: macOS, but single shard. If runtime > 30 min, shard by suite.
- Estimated monthly spend with caching + filters: ~300-500 macOS minutes, ~2000 Linux minutes → stays inside free tier for a 2-person repo.

---

## 7. Maintenance Discipline

Test rot kills test suites. These are the levers.

### Per-PR checklist (PR template)
- [ ] Tests added or updated for the change
- [ ] If fixing a bug: named regression test added (`test_<bug-shortname>`)
- [ ] Goldens regen'd only if visual change is intentional
- [ ] No `skip:` / `@Skip()` without a linked issue
- [ ] CLAUDE.md / docs updated if user-visible behaviour changed

### Tests must accompany feature
- **CODEOWNERS:** `docs/TEST_PLAN.md` owned by Carl; changes require his review.
- **Branch protection on main:** require CI green, require PR review.
- **PR template check** (GitHub Actions job): fail PR if the touched files include `lib/` or `src/` but no `test/` files changed AND the PR body doesn't contain `[no-test-required]` with a reason.

### Flake quarantine policy
- First flake: mark `@tags(['flaky'])` and open an issue. Removed from the default CI filter.
- Second flake (same test within 14 days): assigned to the author of the code under test, deadline one week.
- Quarantined > 30 days: delete the test. It's not protecting anything.

### Monthly suite-health audit (first Monday of each month)
- Run: slowest 10 tests, flake rate, coverage trend, quarantined list.
- Output: a comment on a standing `tests/health` issue. Drops 3 action items.
- Carl triages.

### Where the plan lives
- This file: `docs/TEST_PLAN.md`.
- Changes via PR. Commits touching `docs/TEST_PLAN.md` go in their own PR, not bundled with features.
- A lightweight index in `CLAUDE.md` points here (add to the "Key Documents" list).

---

## 8. Phased Rollout

We can't write everything at once. Aligned with MVP ship on 2026-05-02.

### Phase 1 — This week (2026-04-18 → 2026-04-25): minimum viable safety net

Goal: protect against the code-review regressions before Melissa onboards. ~15-20 tests total.

Files to create, in priority order:

```
supabase/tests/
  rls_credit_ledger_test.sql          # blocks client-side refund mint (scenarios 22, 24, 25)
  consume_credit_atomic_test.sql      # ordering + atomicity (scenarios 19, 20, 21)
  get_plan_full_anon_test.sql         # anon can read, no direct SELECT (scenarios 9, 62)
  rls_practice_scoping_test.sql       # helper fns + recursion guard (scenarios 7, 8, 9)

app/test/
  services/upload_service_ordering_test.dart   # consume_credit before plans.upsert (scenario 12)
  services/upload_service_refund_test.dart     # refund path on upload failure (scenario 14)
  services/conversion_service_queue_test.dart  # FIFO + restart (scenario 57, 60)
  screens/auth_gate_bootstrap_test.dart        # bootstrap failure surfaces (scenario 3)
  screens/home_screen_error_test.dart          # _loadSessions no-hang (scenarios 64, 65)
  utils/credit_cost_test.dart                  # ceil(n/8) clamp (scenario 21)

supabase/functions/payfast-webhook/
  index_test.ts                       # signature + IP + replay + amount (scenarios 26-31)

.github/workflows/
  flutter-ci.yml                      # unit + widget only for Phase 1
  supabase-ci.yml                     # pgTAP + deno test
```

Phase 1 explicitly defers: goldens, integration on device, Playwright, web-portal tests.

### Phase 2 — Week 2 (2026-04-25 → 2026-05-02): critical-path coverage

Goal: everything in section 3 marked MVP-critical.

```
app/test/
  goldens/
    studio_no_circuit_test.dart       # scenario 34
    studio_one_circuit_test.dart      # scenario 35 — the bug
    studio_two_circuits_test.dart     # scenario 36
    sign_in_states_test.dart          # four states
  widgets/
    gutter_rail_test.dart
    inline_action_tray_test.dart
    thumbnail_peek_test.dart
    circuit_control_sheet_test.dart
    progress_pill_matrix_test.dart
    undo_snackbar_test.dart
  integration_test/
    sign_in_sentinel_claim_test.dart  # scenarios 1, 2
    capture_to_publish_test.dart      # scenario 11
    offline_degradation_test.dart     # scenario 50 equivalent on app

web-player/tests/
  unit/
    circuit_unrolling.test.js
    rest_consolidation.test.js
    eta_widget.test.js
    sw_cache_policy.test.js
  e2e/
    plan_load.spec.ts                 # scenario 44
    offline_cache.spec.ts             # scenario 50
    whatsapp_og.spec.ts               # scenario 52

web-portal/tests/
  unit/
    credit_balance.test.tsx
    practice_switcher.test.tsx
  e2e/
    signin_to_credits.spec.ts
    payfast_redirect.spec.ts

supabase/tests/
  plan_issuances_audit_test.sql
  pending_payments_state_test.sql

.github/workflows/
  web-portal-ci.yml
  web-player-ci.yml
  integration-nightly.yml
```

### Phase 3 — Post-MVP (2026-05-02 onwards): broaden + harden

- Add Playwright visual diffs on PRs as comments (`playwright-snapshot-report` action).
- Patrol adoption if camera-permission flows need it.
- Device matrix: add iPhone 15 + iPhone SE simulators.
- Android (when/if).
- Property-based tests for credit-cost formula + circuit-unrolling with `glados` (Dart) + `fast-check` (JS).
- Load tests against `get_plan_full` — target 100 RPS with p95 < 300ms from SA.
- Chaos tests: kill publish mid-upload, assert refund lands.
- Accessibility audit automated via `axe-core` on web-player + portal.
- Contract-test generator: read `supabase/schema.sql` → emit Dart + TS types → fail CI if drift.

---

## Open questions for Carl

Please decide before we start writing code:

1. **`patrol` vs raw `integration_test`?** Patrol is more capable for camera/share-sheet flows but adds a native build step. Recommend we **start without patrol**; revisit only if a specific flow can't be expressed in `integration_test`.
2. **pgTAP vs hand-rolled SQL fixtures?** pgTAP is the tool-of-record for RLS testing but requires installing a Postgres extension locally. Recommend **pgTAP** — RLS testing without it is a fool's errand.
3. **Visual diffs as PR comments?** `playwright-snapshot-report` or `reg-cli` can post diff images inline. Worth the setup cost? Recommend **yes, Phase 3**. For Phase 2 we rely on CI artefacts.
4. **Coverage threshold: 70% on changed files OR 70% global?** I recommend **70% on changed files** (via codecov `patch` check). Global thresholds punish legacy code, encourage gaming.
5. **Where does the integration test Supabase instance live?** Options: (a) spin up ephemeral local db in CI per-job, (b) shared staging project, (c) Carl's linked `yrwcofhovrcydootivjx` project with reset-before-test hooks. Recommend **(a) ephemeral local for unit + pgTAP, (b) shared staging for integration + E2E**. Option (c) is dangerous — production data ride-along risk.
6. **Do we commit Playwright traces on every run, or only on failure?** On failure only, to save storage.
7. **Flake threshold for quarantine: 2 failures in 14 days, or more lenient?** Recommend **2 in 14 days** — strict keeps the suite honest.
8. **Who blesses goldens?** Recommend **Carl blesses any golden touching a screen in `app/lib/screens/`; QE agent blesses pure-widget goldens**. Otherwise goldens become a rubber-stamp.
9. **Do we keep the web-player's `test/` alongside `app.js` (colocated) or under `web-player/tests/` (separated)?** Recommend **separated** — easier Playwright root, clean Vercel deploy excludes.
10. **Is there budget (Carl's time) for a weekly 30-min suite-health standup, or is async the only realistic cadence?** Recommend **async-only** — paste audit output into the standing issue, Carl comments when he has time.
11. **PayFast sandbox credentials: can CI have them as repository secrets, or is that compliance-spooky?** Sandbox-only should be fine. Production creds never touch CI.
12. **Do we want a pre-commit hook** (husky-equivalent for multi-language mono-repo) **that runs `flutter analyze + next lint + pgTAP-lint` before a commit?** I'd say **no** — hooks get bypassed; rely on CI.

Once you've answered these, we can start with Phase 1 files. Recommend spawning a sub-agent to write Phase 1 in a single branch so you can review the whole safety net before it lands.
