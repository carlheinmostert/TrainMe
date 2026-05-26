# Autonomous execution log — artifact-system implementation

**Date:** 2026-05-26 (started while Carl was AFK)
**Operator:** Claude (this session)
**Scope:** Implementation Waves 1–5 of the artifact-system design ratified in `docs/ARTIFACT_SYSTEM.md`
**Authority:** Carl said "execute subsequent waves as well and document your decisions so that I can review them when I get back."

This document is the running record of every consequential decision I made without Carl in the room, plus the state of each wave at handoff. Read this before the individual wave PRs.

## Decision standing-rules (apply to all waves)

1. **Branch from `origin/staging`**, NOT main. Per `feedback_branch_sub_agent_from_staging.md`. Each wave gets its own branch named `feat/artifact-{slug}` off staging.
2. **PR target = `staging`**, never main. Carl explicitly promotes staging → main; I don't touch that boundary.
3. **No iOS device install, no TestFlight, no `flutter run`.** Per `feedback_ask_before_mobile_deployment.md`. Simulator builds OK for verification.
4. **Schema migrations as files only.** No `supabase db push`, no `mcp__supabase__apply_migration`, no dashboard SQL editor. Per `feedback_supabase_branching_one_source.md`. If Branching is wedged on staging (per 2026-05-11 incident), I'll attempt `supabase db query --linked --file` from this session as the documented "last resort" path and flag the manual-apply state in the wave's PR body. If that path also fails I PAUSE and report.
5. **All reads/writes through enumerated RPCs.** Per `feedback_no_direct_db_access.md`. Never `from('table').select()` from `api.js` / `api_client.dart` / `api.ts`. The per-surface access layer files are the only enumerated surface.
6. **Vocabulary:** "workout handout" + "workout player" (never "overview" / "interactive player"). "Practitioner", never trainer/coach/bio/physio in copy. Single coral accent.
7. **Reader-App safe:** no purchase paths, no buy buttons, no price strings in the Flutter app. "Save your plan" / "Spend N credits" are OK. Top-up always at `manage.homefit.studio`.
8. **R-10 parity** only where it applies (player UX changes touch both `app/` and `web-player/`). The handout is web-only — no Flutter mirror needed.
9. **homefit.studio wordmark** — `.studio` (dot + word) is coral, not muted grey. Per `feedback_homefit_studio_wordmark.md`. The seal uses `--seal-coral` / `--seal-coral-light` at `:root`, never overridden by `.skin-{name}` classes.
10. **Sub-agents:** repo-relative paths, no `/Users/chm/dev/TrainMe/...` absolute prefixes. Per `feedback_agent_worktree_isolation.md`.
11. **Watchers print, they don't merge.** Per `feedback_sub_agent_watcher_prints_only.md`. I do the merging.

## Wave 1 — Foundation (handout + multi-kind publish)

**Branch:** `feat/artifact-handout-foundation` (deleted after merge)
**PR:** #533 — **MERGED to staging** as squash commit `5715efd`
**Reading order for review:** `docs/ARTIFACT_SYSTEM.md` (the design) → ADRs 0022, 0025, 0027 → PR #533

### Decisions made without Carl

- **Kept `web-player/lobby.js` mostly intact** (agent's judgement call). The original brief said delete the file; agent discovered it's 3,526 lines and houses the player's pre-workout entry surface (hero matrix, gear popover, treatment pills, body-focus, Start-Workout button, settings popover, hero-crop hydration, signed-URL expiry recovery) — not just the PDF export. Agent removed only the export region (~1,300 lines: `triggerLobbyShare` + helpers + constants + `lobby-share-btn` wiring) and left the rest. ADR 0025 only called for deleting the export path anyway — the original brief was over-broad on this single instruction. **I agree with the agent's call; revisit if the player misbehaves.**
- **`plan_issuances.kind` made nullable** (agent's call). The existing client-side INSERT via RLS policy `plan_issuances_insert_own` keeps writing rows without `kind`; new RPC writes filled-in rows. Revoking INSERT from `authenticated` belongs to Wave 3 when the Flutter publish flow moves into the new RPC.
- **`status` enum left untouched.** ADR 0022 + the design doc propose `offered → rendering → ready → failed`. Existing constraint is `pending → generating → ready → failed`. Computed kinds (handout) go straight to `'ready'`; no functional difference. Migrating the enum is a separate later concern.
- **Manual mirror sync** (my call, post-agent). The drift guard failed because the agent updated `web-player/*` but didn't sync to `app/assets/web-player/*`. I attempted `dart run app/tool/sync_web_player_bundle.dart` which crashed on a native-assets compile error on this Mac. Manual `cp` of every modified+new file did the equivalent. Committed as `chore(artifact-system): sync web-player mirror for Wave 1 handout`.
- **Rebase onto current staging** (my call, post-agent). The pre-rebase CI had 2 Flutter test failures in `face_enrolment_service_test.dart` — pre-existing failures fixed by PR #534 (Vision streamed-yaw rebuild Phase 2) that landed on staging while Wave 1 was being implemented. Rebasing onto `f69a6c3` (then-current staging tip) resolved them.

### Pre-flight findings against live staging DB

Agent verified:
- `get_plan_full` is `RETURNS jsonb`, NOT `RETURNS TABLE`. Migration carries the whole existing body forward and only extends the `v_artifacts` sub-select. Every existing key (three-treatment URLs, sets, thumbnails, brand colour, public profile) preserved.
- `consume_credit` already upserts a `plan_url` `plan_artifacts` row on all three publish paths (paid, free self-trainer, prepaid unlock). New `publish_plan_artifacts` RPC rides on top via `ON CONFLICT ... DO UPDATE` (idempotent; re-ticking is no-op).

### Manual-apply state

**Branching CI applied the migration cleanly** — "Apply all migrations against Postgres 17" check passed. Supabase Preview branch DB also populated successfully. No manual `supabase db query --linked --file` needed for this wave. The `feedback_supabase_branching_one_source.md` "Branching wedged" memory may be stale; future waves can default to git-only apply unless CI reports otherwise.

### Files touched

15 files, +2,098 / -2,138 (net smaller — deprecation removed more than the handout added):

- **New:** `supabase/migrations/20260526150953_artifact_system_foundation.sql`, `web-player/handout.{html,css,js}`
- **Modified:** `web-player/{api.js, middleware.js, vercel.json, sw.js, index.html, lobby.js, styles.css, app.js}`, `app/lib/screens/unified_preview_screen.dart`, full mirror in `app/assets/web-player/`
- **Deleted:** `web-player/{html2canvas.min.js, jspdf.umd.min.js}` + mirror copies

---

## Wave 2 — Claim + consumer identity

**Branch:** `feat/artifact-claim-consumer-identity` (deleted after merge)
**PR:** #535 — **MERGED to staging** as squash commit `337fff9`

### Decisions made without Carl

- **Skipped the `plan_invitations` extension.** Agent's pre-flight found the table doesn't exist on staging. The brief had said "extend with `claimed_by_user_id`"; without the table to extend, the claim flow writes only to `client_accounts` + `audit_events`. ADR 0024's "loop closed by matching the claimed plan, not the address" still holds — `client_accounts.practice_client_id` does the loop-closing.
- **Used live consent key `safe_mode_face_recognition`** (not `face_recognition` as the design doc prose names it). The consumer-facing label stays "Face fingerprint" — only the DB key name diverges. Flag in case other waves reference the design-doc name.
- **Consumer RPC named `list_my_plans()`** to avoid collision with the existing practitioner-side `list_my_workouts()` (self-trainer wave).
- **Audit table is `audit_events`**, not `plan_issuances` as the brief suggested. New event kinds (`artifact.claimed`, `artifact.claim_reattempted`, `consumer.consent.update`) are unconstrained text so no CHECK to extend.

### Files touched

- New migration: `supabase/migrations/20260526173515_artifact_system_claim.sql` (745 lines — `client_accounts` table + 5 RPCs: `claim_plan`, `list_my_plans`, `list_my_practitioner_relationships`, `set_my_consent`, `get_effective_consent`).
- New web routes: `web-player/me.{html,css,js}`, `web-player/me-data.{html,css,js}`.
- Extended `web-player/api.js` (8 new HomefitApi methods).
- Wired claim chip on `web-player/handout.js` → `/me?claim=<planId>`.
- `web-player/vercel.json` rewrites for `/me` and `/me/data`.
- Full mirror sync in `app/assets/web-player/`.
- Test script: `docs/test-scripts/2026-05-26-artifact-system-wave2.md` (19 items).
- Auth config handoff: `docs/handoffs/2026-05-26-wave2-auth-config-needed.md`.

### Blocker for E2E testing — Carl-side action required

Supabase Auth redirect allowlist needs **4 new entries** on both prod (`yrwcofhovrcydootivjx`) and staging (`vadjvkmldtoeyspyoqbx`) projects:
- `https://session.homefit.studio/me/**`
- `https://session.homefit.studio/me`
- (staging equivalents)

Full runbook (Management API + dashboard fallback) at `docs/handoffs/2026-05-26-wave2-auth-config-needed.md`. **Test items 1-3 work without this; items 4+ blocked until applied.** Per `feedback_use_apis_not_dashboards.md` we'd normally do this via Management API; left to Carl because it touches both prod and staging.

---

## Wave 3 — Practitioner publish surfaces

**Branch:** `feat/artifact-publish-gate` (deleted after merge)
**PR:** #536 — **MERGED to staging** as squash commit `6ebefb9`

### Decisions made without Carl

- **Paid-only lock predicate uses `credits_charged > 0`**, not "any plan_artifacts row exists." Agent's pre-flight found that `consume_credit` already upserts a `plan_artifacts` row on every paid + free-publish + prepaid-unlock branch — meaning the naive "row exists" predicate would have wrongly locked self-trainer free plans + prepaid-unlock republishes. The `credits_charged > 0` check uses the persisted charge stamp as provenance. Documented inline in the migration `20260526173554_plan_has_paid_artifact.sql`. **This is a load-bearing correction to ADR 0028's implementation; the ADR's rationale stays correct but the predicate sentence needs updating to "any artifact with credits_charged > 0" rather than "any paid artifact exists."**
- **`prepaid_unlock_at` handling** kept in `upload_service.dart` (not propagated through `publish_plan_artifacts` return shape). Read from local pre-call snapshot. Functionally equivalent.

### Files touched

- 2 new migrations: `20260526173554_plan_has_paid_artifact.sql` + `20260526173718_list_plan_artifact_statuses.sql`.
- `app/lib/services/api_client.dart` — 314 lines added (3 new RPC methods + types).
- `app/lib/services/upload_service.dart` — `consume_credit` → `publishPlanArtifacts` swap with `kinds: [...]` param.
- New widgets: `app/lib/widgets/publish_gate_sheet.dart`, `app/lib/widgets/artifact_status_row.dart`.
- `app/lib/screens/studio_mode_screen.dart` — gate wiring + status row mount + paid-only lock refactor + unlock-sheet copy refresh.

### Verification

- `flutter analyze` clean.
- `flutter test` — 151 passed, 0 failed.
- CI all green (21 pass, 0 fail).
- No device install attempted (per `feedback_ask_before_mobile_deployment.md`).

---

### Locked decisions Carl approved before stepping away

- **Auth model:** reuse `auth.users` for claimed consumers (same row type as practitioners, differentiated by which side of the relationship they sit on).
- **Link-table:** new `client_accounts (consumer_user_id, practice_client_id, consent jsonb, claimed_at, created_at)` PRIMARY KEY `(consumer_user_id, practice_client_id)`. One row per consumer × practice relationship; consent jsonb overrides `clients.video_consent` once it exists.
- **Plan-claim mechanism:** extend the existing `plan_invitations` table (shipped on staging with the self-trainer wave) with a `claimed_by_user_id` column + status transition.
- **Routes:** `/me` (consumer's My Workouts) and `/me/data` (consent panel) — locked during visual phase walkthrough.

### Decisions made without Carl

(populated when the wave runs)

---

> Wave 3 outcome moved up to sit alongside Wave 2 (which it landed in parallel with). The original Wave 3 stub is removed.

---

## Wave 4 — Brand-skin subscription

**Branch:** `feat/artifact-brand-skin-subscription` (deleted after merge)
**PR:** #539 — **MERGED to staging** as squash commit `b543130`

### Locked decisions Carl approved before stepping away

- **Price:** 4 credits/month (R100 at R25/cr).
- **Trial:** 30-day free trial on first subscription (debit starts day 31).
- **Lapse grace:** 7-day window with banner before chrome reverts.
- **Scope:** one skin per practice (multi-practice practitioner subscribes each independently).
- **Ledger kind:** `brand_skin_month`, `metadata = '{"practice_id": "<uuid>"}'`.
- **Renewal:** manual re-up via portal subscribe surface, push-notification reminder at day 25 (mirrors ADR 0021 Safe Mode pattern).
- **CSS architecture:** `.skin-{name}` class overrides `--brand-default` + `--brand-light` + `--brand-tint-bg` + `--brand-tint-border` + `--brand-glyph-bg`; `--seal-coral` + `--seal-coral-light` at `:root` never overridden.

### Decisions made without Carl

- **Salvaged mid-flight after the sub-agent died with a truncated message.** The Wave 4 backend-architect agent (`a1f645c5e16812d3a`) sent a completion notification with the final summary cut off at "Now wire the banner into BrandHeader:" — clearly mid-instruction. Verified the worktree state per `feedback_dead_agent_salvage.md`: the agent had landed the migration (32 KB, well-architected), the `handout.css` `.skin-active` override block, the `handout.js` `applySkin()` color-derivation pipeline, the `BrandSkinLapseBanner.tsx` component, and the four `PortalApi` methods — but had NOT yet (a) mounted the lapse banner into `BrandHeader`'s JSX (only added the import), (b) authored the `/brand-skin` + `/brand-skin/subscribe` portal routes, (c) added the mobile `ApiClient` brand-skin methods + `BrandSkinState` class, or (d) built the Flutter Studio lapse banner widget. Parent session authored those four missing pieces by hand against the agent's existing pattern (BrandSkinLapseBanner mirror, SafeModeSubscribeForm mirror, ApiClient pattern mirror). All deliverables present at PR open.
- **`.skin-active` (not `.skin-{name}`)** for the CSS class. The locked-decisions block named `.skin-{name}` but the implementation reality is that the practitioner's brand identity is passed inline via CSS custom properties (`--practice-brand-*`); the class is just a binary toggle for "skin on / skin off." Class name divergence documented inline in `handout.css`.
- **Added `credit_ledger.metadata jsonb` column** (the migration introduces this — pre-existing schema didn't have it). The spec named `metadata->>'practice_id'` as the scope key, so we added the column rather than scoping by the existing `credit_ledger.practice_id` (which would have worked here, but wouldn't generalise — Safe Mode is user-scoped, not practice-scoped, so a future cross-cutting predicate needs the metadata path). Documented inline.
- **`practice_brand_skin_state` soft-fails on non-member** (returns inactive snapshot) rather than raising. Rationale: portal practice-switcher routes can carry a stale `?practice=` link; a hard raise would crash the page, whereas the inactive snapshot just hides the lapse banner. Mirrors a pattern Safe Mode does NOT use (Safe Mode raises) — divergence is deliberate because the brand-skin banner is informational, not gating capture.
- **Partial index** `credit_ledger_brand_skin_lookup` on `((metadata ->> 'practice_id'), type, created_at DESC) WHERE type IN ('brand_skin_month', 'brand_skin_month_trial')` so the predicate hot path stays small.
- **Trial-then-paid fall-through** on the portal subscribe form: if `start_brand_skin_trial` returns `trial_already_used`, the form switches to the paid CTA inline (no page reload). Smoother UX than redirecting to a different form.
- **Studio banner is informational only.** No CTA, no tap target, no price string — Reader-App compliant per `feedback_ios_reader_app.md`. Practitioner reads the cycle-end warning and must visit `manage.homefit.studio` from a browser to renew.
- **`get_plan_full` extension preserves every existing key.** Sourced the previous body from `20260526150953_artifact_system_foundation.sql` (Wave 1) and added only the `brand_skin_active` field. Per `feedback_schema_migration_column_preservation.md`.
- **Rebased onto the post-Wave-1-2-3 staging tip mid-flight** when CI surfaced a base mismatch. While the Wave 4 agent ran, two additional commits landed on staging (`8a4c735` M40 ARKit, `9815b70` safe-mode self-recognition fix). Clean conflict-free rebase since face-enrolment iOS files don't overlap Wave 4 scope.

### Files touched

16 files, +2,366 / -10:

- **New:** `supabase/migrations/20260526184005_brand_skin_subscription.sql`, `web-portal/src/app/brand-skin/page.tsx`, `web-portal/src/app/brand-skin/subscribe/page.tsx`, `web-portal/src/app/brand-skin/subscribe/BrandSkinSubscribeForm.tsx`, `web-portal/src/components/BrandSkinLapseBanner.tsx`, `app/lib/widgets/brand_skin_lapse_banner.dart`.
- **Modified:** `web-player/handout.{html,css,js}` + mirror at `app/assets/web-player/handout.{html,css,js}`, `web-portal/src/components/BrandHeader.tsx`, `web-portal/src/lib/supabase/api.ts`, `app/lib/services/api_client.dart` (+ `BrandSkinState` class), `app/lib/screens/studio_mode_screen.dart`.

### Verification

- ✅ `dart_analyze` clean on the touched paths.
- ✅ Seal-token grep on `handout.css` confirms `--seal-coral` / `--seal-coral-light` / `--seal-tint-border` declared only at `:root` + the `.handout-seal` rule — never inside `.skin-active`.
- ✅ Web-player mirror sync verified.
- ✅ CI all 23 checks green (Flutter analyze + test, Web portal lint + typecheck + build, Web player node --check, Apply all migrations against Postgres 17, Supabase Preview, etc.).

---

## Wave 5 — Share sheet + managed email

**Branch:** `feat/artifact-share-managed-email` (deleted after merge)
**PR:** #541 — **MERGED to staging** as squash commit `93313c4`

### Scope (delivered)

- Share sheet two-path UI in Flutter (mockup at `2026-05-26-share-sheet.html`) — managed email + OS share. Pre-fills from cached `clients.email`.
- Edge function `send-artifact-email` for Resend-backed branded artifact link delivery. JWT-authed + practice-membership-scoped.
- `clients.email` + `clients.email_verified_at` columns. Practitioner-typed value lives in `clients.email`; supersedes to a verified value when the recipient claims the plan with a confirmed `auth.users.email` (per ADR-0024). The `send-artifact-email` function refuses to overwrite a verified email.
- `set_client_email(uuid, text)` RPC + `claim_plan` extension for the supersession.

### Decisions made without Carl

- **Salvaged after the agent died with a truncated message.** Like Wave 4, the agent (`ae0c37e71c3206c2d`) ended with "The output is empty (1 line). Test must be still building/running. Let me wait via the monitor." — clearly mid-monitoring. All eight deliverables were present in the worktree (migration, edge function, share-sheet widget, test script, 4 modified Dart files) but uncommitted and no PR opened. Parent session committed the agent's work as-is, opened the PR, then surfaced + fixed a test failure (see below).
- **`idempotent_migration_test` follow-up commit** (test-only). The agent bumped `_dbVersion` 48 → 49 in `local_storage_service.dart` to land the two new `cached_clients` columns (`email` + `email_verified_at`), but didn't update the two `expect(version.first['user_version'], 48)` assertions in `app/test/idempotent_migration_test.dart`. CI surfaced the failure; parent session bumped both assertions to 49 and pushed as a follow-up commit (`971e72b`) before merge. Same wave, same PR.
- **`cached_clients.email` was added to the local-cache table beyond the brief.** The brief specified mobile-side `ApiClient` wiring + `ArtifactShareSheet` widget but didn't explicitly ask for SQLite columns. The agent extended scope to plumb both columns through the local cache so the share-sheet pre-fill works offline. Consistent with the offline-first architecture; left in.
- **Two-path share sheet falls through to OS share when `client_id` is null** (legacy sessions without a clients linkage). The agent built this as an explicit branch — `_shareFromToolbar` checks for `clientId` and routes to `Share.share()` directly. Pre-Wave-5 single-path behaviour preserved for orphan rows.
- **Resend integration via HTTP API (not SMTP).** The agent calls `https://api.resend.com/emails` with the same Resend account that powers SMTP auth-email delivery. Carl needs to (a) generate an API key from the Resend dashboard, (b) set `RESEND_API_KEY` as a Supabase edge-function secret, (c) deploy the function. Documented in the PR body — until done, the share sheet's email CTA returns 500 and falls back gracefully; the "Share link" path works unchanged.

### Files touched

10 files, +2,032 / -17:

- **New:** `supabase/migrations/20260526192442_artifact_share_managed_email.sql`, `supabase/functions/send-artifact-email/{deno.json,index.ts}`, `app/lib/widgets/artifact_share_sheet.dart`, `docs/test-scripts/2026-05-27-artifact-system-wave5.md`.
- **Modified:** `app/lib/services/api_client.dart` (+103 lines: `setClientEmail`, `sendArtifactEmail`), `app/lib/models/cached_client.dart` (+48: email + emailVerifiedAt fields + decode), `app/lib/services/local_storage_service.dart` (+31: v49 migration), `app/lib/screens/studio_mode_screen.dart` (+75: share-sheet wire-in), `app/test/idempotent_migration_test.dart` (+2/-2: assertion bump).

### Verification

- ✅ `dart_analyze` clean on touched paths.
- ✅ Flutter test: 168 tests passed, 0 failed (after the assertion fix; initial CI surfaced 2 failures).
- ✅ CI all checks green (Apply migrations against Postgres 17, Flutter app analyze + test, Web portal lint + typecheck + build, Web player node --check, Supabase Preview, etc.).
- ⏳ Edge function not yet deployed — needs `RESEND_API_KEY` secret + `supabase functions deploy send-artifact-email`. Carl-side action.

---

## Outstanding for Carl to review on return

(populated as I go — anything that needed a defensible call I'll log here so you can override before final merge)

## Final state at handoff

(populated at the end — links to all PRs, current staging tip, any unresolved blockers)
