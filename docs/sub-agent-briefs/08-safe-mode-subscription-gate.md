# Brief — PR #8: Safe Mode subscription gate at capture entry + paywall sheet

**Target branch:** `feat/safe-mode-subscription-gate`
**Target merge:** `staging`
**Depends on:** PR #1 (schema — `safe_mode_grandfathered`, ledger kind)
**Sensitive zone:** billing — touches `credit_ledger` write semantics indirectly

## Context

`docs/SELF_TRAINER_WAVE.md` § "Safe Mode subscription model".

This is the paywall PR — when a user enters Camera mode inside an enforcing Safe Mode geofence without an active sub / trial / grandfathered status, they hit a paywall sheet instead of the camera viewfinder. The portal handles the actual subscription purchase (Reader-App compliance).

## Acceptance criteria

1. **`is_in_active_safe_mode_sub(p_user_id uuid)` SQL fn** (new SECURITY DEFINER STABLE) — full body per design doc. Returns true if any of: (a) grandfathered, (b) active `safe_mode_month` ledger row within 30 days, (c) active `safe_mode_month_trial` ledger row within 3 days. Migration: `YYYYMMDDHHMMSS_safe_mode_sub_gate.sql`. Same migration drops the index `credit_ledger_safe_mode_lookup` from PR #1 if needed (verify it landed there first).

2. **`start_safe_mode_trial(p_user_id uuid) RETURNS boolean` RPC** — writes one `kind='safe_mode_month_trial'`, `amount=0` row to `credit_ledger` for the user. Idempotent — if a trial row already exists (any age), returns false (no second trial). Returns true on success.

3. **Subscription debit RPC** — `start_safe_mode_subscription()` (called from the portal, NOT mobile). SECURITY DEFINER. Debits 4 credits from `credit_ledger` (`kind='safe_mode_month'`, `amount=-4`). Checks balance first; returns error if insufficient. Atomic — same locking pattern as `consume_credit`.

4. **Gating check at capture entry** — in `app/lib/screens/capture_mode_screen.dart` (or wherever the entry path lives), before camera initialisation:
   ```dart
   if (SafeModeService.instance.isActive) {
     final hasAccess = await ApiClient.instance.isInActiveSafeModeSub(userId);
     if (!hasAccess) {
       showPaywallSheet(); // see below
       return; // bail out of camera init
     }
   }
   ```

5. **Paywall sheet** — `app/lib/widgets/safe_mode_paywall_sheet.dart` (new). Bottom sheet (NOT modal). Content:
   > **Safe Mode subscription required to capture here**
   > You're at [Premises Name]. Captures inside protected spaces use Safe Mode (which blurs anyone else around you).
   > Try Safe Mode free for 3 days — then 4 credits / month to keep going.
   > [ Start free trial ]    [ Not now ]
   On "Start free trial": calls `start_safe_mode_trial()`; on success, dismisses sheet, retries camera entry (now passes gate via trial row). On already-had-trial: copy changes to "Subscribe at manage.homefit.studio · 4 credits / month" with a deep-link button (Reader-App compliant — no in-app prices, no Subscribe button; just the deep link).

6. **Safe Mode banner sub-status chip** — in `app/lib/widgets/safe_mode_banner.dart` (or wherever the banner renders), add an embedded chip showing current sub state:
   - Subscriber (paid): `"sub active · N days left"`
   - Trial: `"trial · N days left"`
   - No sub: `"subscribe to capture here →"` (tap deep-links to portal)
   - Grandfathered: `"sub included"` (or simply hide the chip)

7. **Portal subscription page** — `web-portal/src/app/safe-mode/page.tsx` (new). Single CTA "Subscribe to Safe Mode · 4 credits / month · 3-day free trial on first sub". Calls `start_safe_mode_subscription` via the existing authed PortalApi. Returns to a success screen on completion.

8. **R-10 parity** — N/A for the mobile paywall sheet itself; portal page is a peer surface, not a parity target.

9. **Test script** — `docs/test-scripts/2026-05-25-safe-mode-paywall.md`. Items: (a) cold-install user enters geofence → paywall appears with "Start free trial"; (b) tap trial → access granted for 3 days; (c) day 4 enter geofence → paywall appears with "Subscribe at manage.homefit.studio"; (d) subscribe on portal → mobile access restored; (e) grandfathered user → no paywall, no chip; (f) lapsed sub user → re-paywall but no trial CTA (trial already used); (g) lapse: existing captures still play.

## Hard rules

- **Repo-relative paths only**.
- **Sensitive zone — billing change. Carl reviews subscription debit RPC before merge.**
- **Reader-App compliance** (per `feedback_ios_reader_app`) — NO in-app prices, NO Subscribe buttons in mobile app, only "subscribe at manage.homefit.studio" copy + deep links.
- **No direct DB access** from any surface — all via RPCs.
- **No mobile deployment.**
- **Sub status check must be cached locally** to avoid network round-trip on every camera entry — refresh on app launch + every 1 hour while app is foreground.
- **No emojis.**
- **Branch**: `feat/safe-mode-subscription-gate`.
