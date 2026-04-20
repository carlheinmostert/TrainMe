# Cross-Cutting Code Review — 2026-04-19

**Branch reviewed:** `bisect/studio-circuit-header` (at `a60c2bb`)
**Scope:** mobile (`app/`), web-portal (`web-portal/`), web-player (`web-player/`), `supabase/`, `docs/`.
**Mode:** read-only. No source changes; this report is the only artefact.

## 1. Executive Summary

1. **Critical — WhatsApp OG preview is silently broken.** `web-player/middleware.js` still reads `plans` + `exercises` directly via PostgREST (lines 17–24). Milestone C locked anon SELECT on those tables; the bot fetch returns empty, middleware falls through to the SPA with no OG tags. Same class of bug that was fixed in `api.js` on 2026-04-18, but middleware was never updated. Melissa's outbound WhatsApp link previews will look broken.
2. **Critical — Brand violation in OG tags.** The same middleware uses the forbidden spellings `HomeFit` and `HomeFit Studio` (lines 51, 55, 57, 61) for OG `title`, `og:site_name`, `twitter:title`, `<title>`. `docs/brand-input.md` says this is explicitly banned. Any WhatsApp/iMessage/Slack preview today shows the wrong brand.
3. **Cross-surface navigation bug.** The mobile app's Settings → Network section links "View full network on the portal" to `https://manage.homefit.studio/account` (`settings_screen.dart:640`), but the referral cards live on `/dashboard`. `/account` only has password+signout+about. R-11 twin is capability-present but mis-linked.
4. **R-06 leak in audit page.** Portal `/audit` still ships a `<th>Trainer</th>` column header (`audit/page.tsx:75`). User-visible.
5. **R-09 violation.** `settings_screen.dart:1142` uses `opacity: 0.5` on stat tiles to dim the "All-time" value when zero — `components.md` explicitly bans `opacity 0.5` as "too ambiguous; use explicit tokens." Portal has the same pattern at `NetworkShareCard.tsx:188` (`opacity-50`).
6. **Referral vocabulary drift.** Portal `/dashboard` labels: "Free publishes available / banked", "Practitioners in your network", "Their PayFast spend". Mobile Settings labels: "Credits banked", "All-time", "In network", "Network spend". Both peer-to-peer-safe, but different phrases for the same numbers. R-11 allows platform differences for form, not labels.
7. **Test coverage is effectively zero.** `app/test/widget_test.dart` is a `expect(1+1, 2)` placeholder. No tests for publish flow, credit consumption, referral RPCs, or any SECURITY DEFINER function. No portal test dir. MVP-critical paths are unexercised.
8. **Canonical schema.sql is stale.** Last touched at the POV — lacks `practice_members`, `credit_ledger`, `plan_issuances`, referral tables, helper fns, `consume_credit`. New-dev bootstrap reading `supabase/schema.sql` would get the wrong shape.
9. **Docs drift.** `CLAUDE.md`, `MVP_PLAN.md`, `BACKLOG_STUDIO_LAYOUT.md`, `PENDING_DEVICE_TESTS.md` all list items that have shipped (progress-pills merged, Studio layout bug fixed, referral backend shipped, auth progressive merged, mobile+portal Settings/Account landed). Reading the docs overstates the work remaining.
10. **Security surface is clean.** No service-role key in client-side code. `createAdminApi()` is only invoked from server route handlers/pages. Anon keys in client bundles are `sb_publishable_*` (designed to be public). `.env.example` passphrase is PayFast's public sandbox default. Credit ledger client writes are revoked at DB level.

## 2. Cross-surface consistency findings

### Auth — mobile vs portal (R-11 twin)
- **Capability parity:** present. Mobile has `SetPasswordSheet` (8-char min, hash strength hint implicit). Portal has `AccountPanel` → `PasswordSection` (8-char min, strength hint visible). Sign-out on both. **OK.**
- **Undo behaviour:** portal has 3s undo countdown on sign-out (`AccountPanel.tsx:187`); mobile sign-out in Settings is immediate — `settings_screen.dart:101` `Sign out` tile. **Inconsistent** — R-01 says destructive actions get undo. Portal is correct; mobile drops the safety net.
- **Strength hint copy:** portal says `Weak / OK / Strong`; mobile has no strength UI beyond the 8-char gate. Minor capability gap.

### Referral — three surfaces (R-11 twin + peer-to-peer voice)
- **Code format + voice:** all three (mobile share template, portal `referral-share.ts`, landing `/r/{code}`) use the same peer-to-peer text: "I use homefit.studio to share exercise plans with my clients — you might find it useful too." Perfect.
- **Stat labels:** drift (see exec summary #6). Mobile "Credits banked" ↔ portal "Free publishes available" refer to the same `rebateBalanceCredits`. Recommend pick one and mirror.
- **Navigation linkback:** mobile's "View full network on the portal" points to `/account`, network cards live on `/dashboard`. **Broken link.** (See exec summary #3.)
- **Self-contained mobile view:** mobile shows compact 4-tile stats but not the referees list; portal has full table. R-11 allows this (mobile lighter). Good.

### Player playback — mobile vs web-player (R-10)
- **Prep-flash overlay:** landed on both (commits `059b828` + `6718284`). Not re-verified pixel-for-pixel in this review, but commit hashes + SW cache bump `v14-prep-flash` indicate parity.
- **Progress-pill matrix + ETA:** Flutter `progress_pill_matrix.dart` and `web-player/app.js` both contain the matrix + ETA widget (`7:42 left` / `~7:42 PM`). Cache name in CLAUDE.md says `v11-pill-matrix` but web-player/sw.js has been bumped further — minor doc lag, not a bug.
- **Rest sage colour:** mobile `AppColors.rest = #86EFAC` matches web-player `--c-rest: #86EFAC`. Match.

### Data-access layer (DAL) compliance
- **Mobile:** clean. Only `api_client.dart` and (for comment-referenced purposes) `upload_service.dart` reference `Supabase.instance.client`. `upload_service.dart` routes through `_api`. ✓
- **Web-portal:** clean. No `.from()/.rpc()/.storage` outside `lib/supabase/api.ts`. ✓
- **Web-player:** partial. `app.js` routes through `HomefitApi`. **But** `middleware.js` bypasses it entirely — direct `fetch('.../rest/v1/plans?...')`. This is both a DAL violation and the cause of finding #1.

## 3. Voice + brand audit — violations

| Surface | File:line | Current | Fix |
|---|---|---|---|
| web-player | `middleware.js:51,57,61` | `— HomeFit` | `— homefit.studio` |
| web-player | `middleware.js:55` | `HomeFit Studio` (og:site_name) | `homefit.studio` |
| web-player | `styles.css:13` (comment) | `HomeFit Studio Design Tokens` | lowercase; low-priority (comment) |
| web-portal | `audit/page.tsx:75` | `<th>Trainer</th>` | `<th>Practitioner</th>` |
| mobile | `upload_service.dart` lines 15, 134, 249, 278, 476, 529, 538, 544 | comments say "bio / trainer" | comments only — low priority, but a grep-sweep keeps R-06 honest |
| mobile | `home_screen.dart:18, 22, 130`, `session_shell_screen.dart:106`, `models/session.dart:8`, many others | same — comments reference "bio"/"trainer" | comments only |
| mobile | `app/lib/theme.dart:4`, `widgets/branded_slider_theme.dart:48`, `theme/motion.dart:4`, `theme/flags.dart:2` | file headers `HomeFit Studio` | lowercase; comment-only |

No user-visible `earn / commission / reward / cash / payout / downline / MLM / affiliate` strings anywhere. Only in defensive comments that document what NOT to write.

Single-accent rule: coral `#FF6B35` is consistent across `theme.dart`, `styles.css`, `tailwind.config.ts`. Sage `#86EFAC` is only on rest surfaces. Clean.

## 4. Security observations

Clean overall. Specifics:

- **No service-role key in client bundles.** `createAdminApi()` throws if the key is missing rather than silently falling back. All three callers (`credits/purchase/route.ts`, `credits/return/page.tsx`, `api.ts`) are server-only.
- **No hardcoded JWTs** (only `sb_publishable_*` anon, which is designed to be shipped).
- **Credit ledger lockdown enforced at DB.** `schema_milestone_e_revoke_credit_ledger_writes.sql` revokes INSERT/UPDATE/DELETE from anon+authenticated. One dead code path remains in `api.ts:287 applyPendingPayment()` — zero callers; could be deleted for safety-in-depth.
- **RLS on plans/exercises** is tight. The web-player RPC `get_plan_full` is the only anon door. This is why `middleware.js` (finding #1) returns empty results.
- **No `TODO: security`/`TODO: auth`** except `upload_service.dart:744` (raw archive cloud upload parked until auth).
- **PayFast webhook** validates via 4 gates (signature / IP / validate / amount) before writing ledger rows. Verified at `supabase/functions/payfast-webhook/index.ts`.

## 5. Test coverage inventory

**Exists:** `app/test/widget_test.dart` (1 placeholder test).
**Missing:**
- Publish flow (`upload_service.dart`): 8-step choreography, refund compensator, pre-flight validation, practice-id resolution fallback, orphan cleanup. Zero tests.
- Credit consumption RPCs: `consume_credit`, `refund_credit`, `bootstrap_practice_for_user`, `record_purchase_with_rebates`, `practice_credit_balance`. Zero tests.
- Referral RPCs: `generate_referral_code`, `claim_referral_code`, `referral_dashboard_stats`, `referral_referees_list`, `referral_landing_meta`, `revoke_referral_code`. Zero tests.
- Web player player logic (`app.js` 1,700+ LOC): timer state machine, prep countdown, circuit unrolling, pill matrix. Zero tests.
- Auth state machine (AuthGate, magic-link fallback, signInWithIdToken). Zero tests.
- No `npm test` script in `web-portal/package.json`. No E2E (Playwright / Cypress).

**Recommended MVP-critical test seeds:**
- `pgTAP` (or a Dart integration harness that calls Supabase linked-local) for the five business-logic RPCs. High value — these are SECURITY DEFINER and control money.
- A `UploadService.uploadPlan` unit with mocked `ApiClient` for the step-ordering contract (consume-before-upsert-version, refund-on-post-consume-failure).

## 6. Documentation drift

| File:line | Claim | Reality |
|---|---|---|
| `CLAUDE.md:113-117` | Studio layout bug "unmerged as of 2026-04-18" | Merged in `cfa78e2` / `424bc49` on main |
| `CLAUDE.md:117` | Progress-pill matrix "pending merge of `feat/progress-pills`" | Merged in `8a10786` |
| `CLAUDE.md:135` | Web-player cache name "current target on `feat/progress-pills`: `homefit-player-v11-pill-matrix`" | Latest bumped to `v14-prep-flash` |
| `CLAUDE.md:163-164` | Studio layout bug + progress-pill matrix listed under "Milestones remaining" | Both shipped |
| `CLAUDE.md:44-45` (path `web-portal/src/lib/supabase/api.ts`) | Implicit reference via DAL doc | File exists — OK |
| `docs/DATA_ACCESS_LAYER.md:148` | `web-portal/src/lib/supabase/api.ts` is the single surface | Correct, but note the new `PortalReferralApi` addition would benefit from an RPC-inventory update (generate/revoke/claim/dashboardStats/refereesList/landingMeta) |
| `docs/MVP_PLAN.md:65-103` | Week-1 items listed as work (referral schema, Settings, Account, sandbox D4 etc.) | Most shipped. Marking progress would unblock prioritising the remaining PayFast-prod + legal + support + Melissa onboarding items |
| `docs/BACKLOG_STUDIO_LAYOUT.md:1-4` | "Open. Critical MVP blocker." | Bug is fixed — whole doc is a post-mortem that should move to archive or be deleted |
| `docs/PENDING_DEVICE_TESTS.md` | Lists `fix/studio-reorderable-listview`, `feat/progress-pills`, `feat/auth-progressive-upgrade` as pending | All three merged. File needs a fresh checkpoint covering referral loop, mobile Settings, portal Account, prep-flash, per-user sessions |
| `supabase/schema.sql` | Canonical fresh-install schema | Reflects POV state; lacks practices, members, credit_ledger, plan_issuances, referral_codes, helper fns, consume_credit. Either regenerate via `supabase db dump` or add a banner "See `schema_milestone_*.sql` in order" |

## 7. Architecture observations (flagged but unjudged)

- **Multi-practice at publish time.** `upload_service.dart:221-247` is the cleanest path, but the fallback-to-session-`practiceId` branch (line 240) can still publish against a stale practice if `bootstrap_practice_for_user` has never run for the current user. Edge case; Carl decides whether to throw instead.
- **Offline-first claim.** CLAUDE.md says "entire capture → convert → edit → preview flow is 100% offline. Only Publish touches the network." I did not find a publish-queue or background-URLSession. `upload_service.dart:11-15` acknowledges this: "TODO: move to background URLSession for true non-blocking publish. The CLAUDE.md 'non-blocking publish' claim is aspirational." Worth reconciling docs to match reality, or scheduling the queue work.
- **Dead code:** `AdminApi.applyPendingPayment()` has zero callers now that `applyPendingPaymentWithRebates` is the canonical path. Deleting reduces review surface.
- **`middleware.js` duplicates `SUPABASE_URL` + `SUPABASE_ANON_KEY`** rather than importing `api.js`. Vercel Edge middleware can import modules — worth a small refactor so the DAL is single-source.
- **`ApiClient.raw` carve-out** is the right pragmatic choice for OAuth id_token + `onAuthStateChange`. Document it as a hard cap — don't grow it.
- **`_StatTile` dimmed state in mobile Settings** uses `opacity: 0.5`. R-09 wants explicit tokens. Design debt, not a bug.

## 8. Top 10 prioritised follow-ups (impact / effort)

1. **Fix web-player middleware OG preview + brand casing.** Why: Melissa's every outbound share currently shows wrong brand + empty preview. Effort: 30 min (swap REST-plans fetch for `get_plan_full` RPC; replace HomeFit→homefit.studio; consider dedupe with `api.js`). Owner: single agent (web-simplify). **Top priority — user-facing.**
2. **Fix mobile "View full network" link.** Change `_portalNetworkUrl` in `settings_screen.dart:640` from `/account` to `/dashboard`. Effort: 2 min. Owner: single agent (mobile-simplify).
3. **Unify referral stat labels across mobile + portal.** Pick one vocabulary and mirror. Effort: 15 min. Owner: discuss — Carl decides which phrasing wins, agent applies.
4. **Refresh `CLAUDE.md` + `MVP_PLAN.md` + `BACKLOG_STUDIO_LAYOUT.md` + `PENDING_DEVICE_TESTS.md`.** Mark shipped items, archive the studio-layout post-mortem. Effort: 45 min. Owner: single agent.
5. **Regenerate `supabase/schema.sql`** via `supabase db dump --linked --schema public --data-only=false`. Effort: 5 min plus a visual diff check. Owner: human (Carl runs the CLI).
6. **Sign-out undo on mobile.** Mirror the 3s undo in `AccountPanel.tsx`. Effort: 30 min. Owner: single agent. Raises R-01 parity.
7. **Replace audit page `<th>Trainer</th>` with `Practitioner`.** One-line R-06 fix. Effort: 1 min. Owner: single agent.
8. **Kill R-09 violations (`opacity: 0.5` / `opacity-50`).** Swap for explicit `ink.dark.disabled` tokens in `settings_screen.dart` and `NetworkShareCard.tsx`. Effort: 15 min. Owner: single agent.
9. **Delete `AdminApi.applyPendingPayment()` dead code.** Effort: 2 min. Owner: single agent (or merge with #4 cleanup).
10. **Seed `pgTAP` tests for the five business-critical RPCs.** `consume_credit`, `refund_credit`, `record_purchase_with_rebates`, `claim_referral_code`, `generate_referral_code`. Effort: 3-4 hours for a meaningful first pass. Owner: single agent. Highest long-term safety payoff.

**Not on this list because non-critical or out-of-scope:** Studio comment-only `bio`/`trainer` grep-sweep; minor typography lockup rebrands; offline publish-queue (CLAUDE.md acknowledges aspirational).
