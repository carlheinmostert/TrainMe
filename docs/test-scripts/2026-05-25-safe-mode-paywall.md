# Test script — Safe Mode subscription gate + paywall sheet + portal subscribe page

**PR:** #8 of the self-trainer wave (`feat/safe-mode-subscription-gate` -> `staging`)
**Spec:** `docs/SELF_TRAINER_WAVE.md` Safe Mode subscription model
**ADR:** `docs/adr/0021-safe-mode-subscription-credit-denominated.md`
**Brief:** `docs/sub-agent-briefs/08-safe-mode-subscription-gate.md`

**Sensitive zone:** billing - touches `credit_ledger` write semantics.
Carl reviews subscription debit RPC + paywall copy before merge.

## What this PR ships

1. Migration `supabase/migrations/20260525144158_safe_mode_sub_gate.sql`
   - Widens `credit_ledger_type_check` to admit `safe_mode_month` + `safe_mode_month_trial` kinds.
   - `is_in_active_safe_mode_sub(p_user_id uuid) RETURNS boolean` - STABLE SECURITY DEFINER predicate.
   - `start_safe_mode_trial(p_user_id uuid) RETURNS boolean` - idempotent; writes one trial row.
   - `start_safe_mode_subscription(p_practice_id uuid) RETURNS jsonb` - atomic 4-credit debit (mirrors `consume_credit` FOR UPDATE pattern).
2. Mobile capture-entry gate in `app/lib/screens/capture_mode_screen.dart`:
   - New `_assertSafeModeSubGate()` helper called from `_capturePhoto` + `_startVideoRecording`.
   - Surfaces `SafeModePaywallSheet` when Safe Mode is active AND the cached/network gate returns false.
3. New `app/lib/widgets/safe_mode_paywall_sheet.dart` - bottom-sheet paywall.
   - "Start free trial" CTA on first-time path -> calls `startSafeModeTrial(auth.uid())`.
   - "Open manage.homefit.studio" CTA on post-trial path -> deep-links to portal `/safe-mode/subscribe`.
   - Reader-App compliant: no in-app prices, no in-app Subscribe button.
4. New `app/lib/services/safe_mode_subscription_service.dart` - local cache + freshness policy.
   - Hourly stale window; refresh on app launch and on resume.
   - Persists `(hasAccess, fetchedAt)` to SharedPreferences keyed per-user.
5. Sub-status chip embedded in `app/lib/widgets/persistent_safe_mode_banner.dart`.
   - "sub included" pill when cached `hasAccess == true`.
   - "subscribe to capture here ->" pill when cached `hasAccess == false` (tap deep-links to portal).
   - Hidden entirely when the cache is unknown (cold start).
6. Portal page `web-portal/src/app/safe-mode/subscribe/page.tsx` + client form.
   - Owner-only CTA "Subscribe - 4 credits / month - 3-day free trial on first sub".
   - Surfaces current balance pre-tap.
   - Insufficient-credits branch routes to `/credits`.
7. `app/lib/services/api_client.dart`: new `isInActiveSafeModeSub` + `startSafeModeTrial` methods.
8. `web-portal/src/lib/supabase/api.ts`: new `getSafeModeSubStatus` + `startSafeModeSubscription` methods on `PortalApi`.

Existing `/safe-mode` public transparency page is unchanged - the subscribe surface lives at `/safe-mode/subscribe` so the two roles do not collide.

## Pre-merge checks (Mac-side)

- [ ] `grep -rn '<<<<<<<\|>>>>>>>' supabase/migrations/ app/lib/ web-portal/src/` returns zero matches.
- [ ] `dart_analyze` clean on the touched files (`api_client.dart`, `capture_mode_screen.dart`, new service, new sheet, persistent banner, `main.dart`).
- [ ] `dart_format` leaves the touched files untouched.
- [ ] `cd app && flutter build ios --debug --simulator` succeeds.
- [ ] `cd web-portal && npm run build` succeeds.
- [ ] CI Supabase Branching: per-PR DB preview applies the migration; the three new RPCs are callable.

## Device test items (post-install)

Run on staging (`https://staging.session.homefit.studio` + `https://staging.manage.homefit.studio`) with the agent QA test account (`qa@homefit.studio`). Requires at least one enforcing premises polygon covering the practitioner's current location.

- [ ] **a. Cold install, no sub: paywall appears with trial CTA.** Fresh install of the staging build, sign in with `qa@homefit.studio` (a user with no prior Safe Mode capture history, no grandfathered flag). Walk into the enforcing premises polygon; the Safe Mode banner goes coral. Tap the shutter (photo). Expect: paywall bottom sheet with title "Safe Mode subscription required to capture here", body name resolves to the configured premises name, primary CTA "Start free trial", secondary "Not now". No price text. No "Subscribe" word in the mobile UI.
- [ ] **b. Tap "Start free trial" -> access granted.** Tap "Start free trial" on the paywall. Sheet dismisses. Take the photo again -> capture succeeds without re-showing the paywall. Banner sub-status chip now reads "sub included".
- [ ] **c. Trial row landed in `credit_ledger`.** In the staging SQL editor: `SELECT type, delta, notes, created_at FROM credit_ledger WHERE trainer_id = '<qa user uuid>' ORDER BY created_at DESC LIMIT 5;` shows one new row with `type = 'safe_mode_month_trial'`, `delta = 0`, `notes` mentions "start_safe_mode_trial".
- [ ] **d. Idempotency: second trial attempt returns false.** From the SQL editor (signed in as the QA user via the portal): `SELECT public.start_safe_mode_trial('<qa user uuid>');` returns `false`. No new `safe_mode_month_trial` row inserted.
- [ ] **e. Day 4 after trial: paywall reverts to portal hand-off.** Simulate the trial expiry by updating the trial row's `created_at` back ~4 days: `UPDATE credit_ledger SET created_at = created_at - INTERVAL '4 days' WHERE trainer_id = '<qa>' AND type = 'safe_mode_month_trial';`. In the app, force-quit and relaunch (so the cached sub status re-fetches). Walk into the geofence; tap shutter. Expect: paywall sheet now shows "Subscribe at manage.homefit.studio" copy + "Open manage.homefit.studio" CTA. No "Start free trial" button (lifetime trial used).
- [ ] **f. Portal subscribe page renders + active practice is detected.** Tap "Open manage.homefit.studio" -> Safari opens `https://staging.manage.homefit.studio/safe-mode/subscribe`. Sign in if needed. Page shows the active practice in the header, current credit balance, and a single coral CTA "Subscribe - 4 credits / month - 3-day free trial on first sub". A non-owner sees the "Only the practice owner can subscribe" notice instead.
- [ ] **g. Subscribe CTA: insufficient credits branch.** With the practice balance < 4, tap Subscribe. Expect: amber panel "Not enough credits", current balance shown, "Buy credits" button routing to `/credits?practice=<id>`. No `credit_ledger` row was inserted (SQL editor confirms).
- [ ] **h. Subscribe CTA: success path.** Top up the practice to >= 4 credits via the existing PayFast sandbox flow. Return to `/safe-mode/subscribe`. Tap Subscribe. Expect: green confirmation panel "Safe Mode subscribed.", new balance reflects the -4 debit. SQL editor shows one `credit_ledger` row with `type = 'safe_mode_month'`, `delta = -4`.
- [ ] **i. Mobile gate re-passes after subscribe.** Back in the mobile app, force-quit and relaunch (or wait 1 hour for the in-app refresh). Walk into the geofence; tap shutter. Capture succeeds; paywall does NOT appear; banner chip reads "sub included".
- [ ] **j. Grandfathered user: no paywall, no chip.** Sign in as a user whose `practice_members.safe_mode_grandfathered = true` (any user who captured with `safe_mode_active=true` before this PR landed - the PR #1 backfill stamped them). Walk into the geofence; tap shutter. Capture succeeds; paywall never appears. Sub-status chip on the banner reads "sub included" (the boolean cache cannot distinguish grandfathered from active, by design at this PR's scope).
- [ ] **k. Lapsed sub: existing plans still play.** Edit the `safe_mode_month` row's `created_at` to be 31+ days ago. Open the lapsed user's published plan on the web player. Captures play normally; the lapse only gates *future* captures (honor what you sold).
- [ ] **l. Lapsed sub: new capture re-paywall (no trial CTA).** From the lapsed user's mobile app, walk into the geofence; tap shutter. Paywall appears with the "Subscribe at manage.homefit.studio" copy (NOT the trial CTA, since the lifetime trial was already used in test (b)).
- [ ] **m. Banner chip taps through to portal.** With the cached gate `false`, tap the "subscribe to capture here ->" chip on the persistent Safe Mode banner. Safari opens `https://staging.manage.homefit.studio/safe-mode/subscribe`.
- [ ] **n. Video capture path also gated.** With the cached gate `false`, in the geofence, attempt a long-press shutter (video). Paywall appears (the video path now runs the same gate before the v2 video-suppression logic).
- [ ] **o. Outside geofence: no gate, no chip.** Walk out of every enforcing polygon. Safe Mode banner drops after the hysteresis window. Take a photo. No paywall. Chip is gone (banner is hidden).
- [ ] **p. Audit feed unchanged.** Portal audit page renders normally - the new ledger rows (`safe_mode_month`, `safe_mode_month_trial`) do not corrupt the existing audit feed since `plan_issuances` is the audit source, not `credit_ledger`.

## Notes for reviewer

- The chip can only show "sub included" vs "subscribe to capture here" because the cached gate is a boolean. Distinguishing trial vs paid vs grandfathered would need a richer status RPC; out of scope for this PR per "minimum to be useful". Future PR can add `get_safe_mode_sub_status() RETURNS jsonb` if Carl wants the granular copy in the chip.
- Reader-App compliance: every in-app mention of subscribing routes to `manage.homefit.studio` and avoids the word "Subscribe" + any price. The paywall sheet's primary CTA on the post-trial path says "Open manage.homefit.studio" specifically.
- `credit_ledger.practice_id` is NOT NULL; trial rows pick the user's owner-role practice (fallback to first membership). The choice is informational - sub state queries are per-user via `trainer_id`.
