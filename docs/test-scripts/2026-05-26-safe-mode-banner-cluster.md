# Safe Mode banner cluster — M24 / M26 / M27 — 2026-05-26

Three mobile items from `docs/test-scripts/2026-05-25-stack.md` (mobile stack round 4). Strike passes; reply with net-remaining.

## Wave scope

- **M24** — Safe Mode action icon is ALWAYS green, full stop. No conditional state-colour.
- **M27** — Banner tap-to-subscribe (was a silent no-op because the in-app sheet path couldn't find a Navigator ancestor; now hands off to the portal subscribe page in external Safari).
- **M26** — Banner subscribed-state regression guard — sources `hasAccess` from the canonical `SafeModeSubscriptionService` and forces a throttled refresh on banner mount + `AppLifecycleState.resumed` so a portal-side subscribe is picked up within ~1s.

## What to test

- [ ] **1.** **M24** — open Home. The left-cluster Safe Mode action icon is a **green circular badge** (`#3DDC97` fill, `#22C57E` border, soft sage glow). Confirmed in EVERY state — toggle Safe Mode OFF (tap the icon when outside any premises so manual mode flips back off): the icon stays green. Long-press into manual mode: still green. Walk inside an enforcing premises (or use a stub): still green. No coral, no white outline shield anywhere.

- [ ] **2.** **M24** — the off-vs-active state differentiation is visible WITHIN the green badge (e.g. bystander figure slightly ghosted when off, fully punched-out when active). Colour does not change; only the inner shield treatment does.

- [ ] **3.** **M27** — inside an enforcing premises WITHOUT a Safe Mode subscription, tap anywhere on the green banner. iOS opens an external Safari View Controller to `staging.manage.homefit.studio/safe-mode/subscribe` (on the staging build) or `manage.homefit.studio/safe-mode/subscribe` (on prod). The previous "tap does nothing" no-op is gone.

- [ ] **4.** **M27** — subscribed-active banner tap. Inside the same enforcing premises with an active subscription, tap the green banner. iOS opens external Safari to `.../safe-mode` (the manage page) — NOT the subscribe page. Practitioner can cancel / change plan from there.

- [ ] **5.** **M26** — subscribed-state freshness. Background the app while NOT subscribed; subscribe via the portal in a separate browser; return to the app. Within ~1s of resume, the banner's right-edge affordance flips from the chevron `›` to the dark-circle-with-sage-check badge, and the sub-copy flips to `Safe Mode active — bystanders blurred`. (No need to wait an hour for the cache to expire.)

- [ ] **6.** **M26 regression test** — run `flutter test test/widgets/persistent_safe_mode_banner_test.dart` (from `app/`). All 5 tests pass:
  - reads subscription state from the canonical `SafeModeSubscriptionService` (no forked state path)
  - refreshes subscription cache on mount AND on `AppLifecycleState.resumed`
  - tap path routes to the portal subscribe URL via `launchUrl`
  - subscribed-state tap path opens the portal manage page
  - M24 icon renders the green badge in every state — no coral, no white shield outline

## Stack file

This wave closes items M24 / M26 / M27 from `docs/test-scripts/2026-05-25-stack.md`. Strike them through there as well when each passes.

## Build context

- Branch: `fix/safe-mode-banner-cluster`
- Target: `staging`
- Mobile-only — no portal / web player changes.
- PR title: `fix(safe-mode): M24 action-icon-always-green + M27 banner-tap-opens-subscribe + M26 subscribed-state-regression-guard`
