# homefit.studio — Test Strategy

Authored 2026-04-23. Initial strategy — expect revisions as each priority lands.

## Current state

| Surface | Framework wired | Tests today | Gaps |
| --- | --- | --- | --- |
| Flutter app (`app/`) | `flutter_test` + `sqflite_common_ffi` for in-memory SQLite | 2 real tests (`capture_defaults_test.dart`, `publish_dirty_state_test.dart`) + 1 placeholder (`widget_test.dart`) | no widget/golden tests; `SyncService` + `pending_ops` replay uncovered |
| Web player (`web-player/`) | none (no `package.json`) | none | no syntax gate; Vercel deploys without checks |
| Web portal (`web-portal/`) | ESLint + `tsc --noEmit` only | none | no unit/integration/E2E tests |
| Supabase RPCs | none | none | money-handling RPCs untested — explicit gap called out in `CLAUDE.md` |
| CI | none | — | Vercel auto-deploys both web surfaces with no gates |
| Manual QA | `docs/test-scripts/_server.py` on port 3457 with HTML test scripts (pass/fail buttons + notes) | Wave 1 + Wave 2 complete; Wave 3 backlogged | device-only flows still depend on Carl's iPhone sessions |

## Strategy — prioritised

### Priority 1: GitHub Actions CI scaffolding

Run `flutter test` + `flutter analyze` on the app, `npm run lint` + `npm run typecheck` on the portal, and `node --check` on each `web-player/*.js` on every push and PR. Cheap, durable, and closes the "no CI gate" gap before anything else is layered on top.

This strategy doc ships alongside the first CI workflow (`.github/workflows/ci.yml`) as part of the same PR. Everything below builds on that foundation.

### Priority 2: pgTAP tests for business-logic RPCs

Target the money-handling and tenancy-critical RPCs:

- `consume_credit` — atomic FOR UPDATE locking, refund compensation path
- `record_purchase_with_rebates` — single-transaction purchase + rebate ledger inserts
- `upsert_client` / `upsert_client_with_id` — practice-scoped uniqueness, offline-first client UUIDs
- `get_plan_full` — anonymous read surface, consent-gated signed URL shape
- `bootstrap_practice_for_user` — sentinel claim vs. fresh personal practice branching
- `delete_client` / `restore_client` — cascade-by-matched-timestamp behaviour
- Referral single-tier `BEFORE INSERT` trigger — rejects A→B→C chains

Run via `supabase test db` against a dedicated test project (or a Supabase branch on Pro). Closes the explicit gap called out in `CLAUDE.md` under "Backlog".

### Priority 3: Playwright E2E for web player and portal

Two smoke flows, headless in CI, screenshots on failure:

1. **Publish-to-player roundtrip** — seed a plan via service-role key, open `session.homefit.studio/p/{id}` in a headless browser, verify `get_plan_full` returns the expected shape, signed URLs resolve, the three-treatment segmented control renders (with consent-gated disabled states), and the progress-pill matrix paints.
2. **Portal checkout intent** — sign in, navigate to `/credits`, pick a bundle, verify the PayFast sandbox redirect URL is well-formed and the `pending_payments` row lands.

This becomes the R-10 mobile↔web parity guardrail — anything that drifts on the web side trips the suite.

### Priority 4: Widget + golden tests in Flutter

Goldens for `HomefitLogo` (matrix + lockup), the progress-pill matrix, and the Studio card. Widget tests for `SyncService` + `pending_ops` replay to protect the offline-first invariants shipped in Milestone K. Pick these up opportunistically — they land alongside the feature work that touches them.

## Explicit non-goals

This strategy does NOT replace:

- **The manual test-script harness** (`docs/test-scripts/_server.py`) — keep it for device-only flows: camera, haptics, the AVFoundation pipeline, line-drawing aesthetic signoff. Automation complements it; it does not replace it.
- **Carl's device QA on his iPhone** — load-bearing for anything the simulator can't exercise (HEVC decode, real camera, real haptics, physical VPN path).

## Tradeoffs

- **Test Supabase project vs. branching.** Priority 2 and Priority 3 both need a writable Supabase target that isn't production. Options: dedicated test project (~$25/mo on Pro) or Supabase branching on the existing Pro plan. Carl to decide.
- **Golden tests are platform- and font-sensitive.** Pin the Flutter version in CI (already pinned to 3.41.6 in the workflow) to avoid golden churn from toolchain drift.
- **pgTAP tests need seeded fixtures that mirror RLS realities.** Use the SECURITY DEFINER helpers (`user_practice_ids`, `user_is_practice_owner`) to set up test roles; avoid the self-referential recursion trap.

## Roadmap

- **Week 1** — Priority 1 (this PR). CI scaffolding lands. Every PR gated.
- **Week 2–3** — Priority 2. Start with `consume_credit` and the referral single-tier trigger; the rest follow.
- **Week 4+** — Priority 3. Playwright smoke flows.
- **Ongoing** — Priority 4. Added opportunistically when touching the relevant widgets or invariants.

## Success metrics

- Every PR gated by CI (Priority 1 delivers this).
- The money-handling RPCs (`consume_credit`, `record_purchase_with_rebates`) have pgTAP coverage before PayFast production cutover. Non-negotiable gate on that cutover.
- The R-10 parity invariants (progress pills, ETA row, three-treatment control) have at least one Playwright assertion each before the next wave of player UX changes ships.
