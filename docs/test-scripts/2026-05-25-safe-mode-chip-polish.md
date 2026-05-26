# 2026-05-25 Safe Mode chip polish (PR `fix/safe-mode-chip-and-sub-recheck`)

Two items from `docs/test-scripts/2026-05-25-stack.md` (M16 + M17):

- **M16** — Safe Mode subscribe chip shield icon was too tiny to read.
  Bumped from 14 px to 28 px and rebalanced the chip's internal
  padding so the icon doesn't crowd the text. Chip height grows from
  ~26 px to ~40 px; still well under the legacy 95-px banner.
- **M17** — Subscription state was only recognised on cold launch.
  Added a 5-s throttled forced-refresh path triggered on both app
  foreground resume AND geofence false→true transitions. Catches
  "user subscribes on the portal while the app is backgrounded" and
  "user was foregrounded but just walked into the gym".

Item numbers below are independent of the stack file's M-prefix —
strike the number when verified.

## Setup

Sign in to the QA test account on staging (`qa@homefit.studio`).
The account does NOT have an active Safe Mode subscription by
default. Ensure you're inside an enforcing premises (or use the
Studio "Safe Mode" manual toggle as a stand-in — the chip
intentionally renders only for AUTO-mode in-zone, so manual won't
show it; use a real or simulated geofence for full M16 / M17
verification).

## M16 — Chip icon size

- [ ] **1.** Land on Home (Clients list) inside an enforcing
  premises. The coral "Subscribe to capture here →" chip appears
  right-aligned under the AppBar. The shield + figures icon on the
  left of the chip is clearly bigger than before — readable from
  arm's-length viewing distance without having to lean in. Compare
  visually against the screenshot at
  `docs/design/mockups/2026-05-25-safe-mode-banner-compaction.html`
  (option 2 baseline) — the icon should now be roughly 2x bigger
  but the chip overall should still feel compact (about ~40 px
  tall, not the legacy 95-px banner). Text "Subscribe to capture
  here →" must not truncate.

- [ ] **2.** Rotate the device or scroll Home — the chip stays
  pinned under the AppBar, icon size stays consistent, no visual
  jitter.

## M17 — Subscription auto-recognition

- [ ] **3.** With the app foregrounded on Home (chip visible),
  switch to Safari and navigate to
  `https://staging.manage.homefit.studio/safe-mode/subscribe`.
  Complete a sandbox PayFast subscription purchase for the QA
  account. Switch back to the homefit app (tap from the
  app-switcher OR via the URL bounce-back). Within ~1-2 seconds
  the chip MUST disappear (the app re-queried
  `is_in_active_safe_mode_sub` on resume + got back `true`). If
  the chip is still showing 5+ seconds after resume, M17 is broken.

- [ ] **4.** Cancel the subscription on the portal (or use the
  admin DB tool to revoke `safe_mode_subscriptions.active` for
  the QA user). Foreground the app again. Within ~1-2 seconds the
  chip MUST reappear (the resume hook re-queried and got back
  `false`). Confirms the throttle isn't gating LEGITIMATE
  refreshes — the 5-s throttle is per-attempt, not per-result.

- [ ] **5.** While foregrounded, rapidly toggle the app to the
  app-switcher and back 3-4 times in quick succession (< 5 s
  apart). The chip must NOT visually flicker between renders, and
  the network tab (if observing logs) should show only ONE
  `is_in_active_safe_mode_sub` RPC call across the burst — the
  5-s throttle prevents RPC spam.

- [ ] **6.** With a current subscription, walk OUT of an
  enforcing premises (or use Studio's manual Safe Mode toggle to
  flip out then back IN). The geofence false→true transition
  should also trigger a fresh subscription re-check — the
  throttle shares the 5-s window with the resume hook. If the
  subscription is still active, the chip stays hidden; if revoked
  between checks, the chip flickers in for ~1 s while the RPC
  resolves. Either is acceptable — the contract is that the chip
  reflects the CURRENT subscription state within ~1-2 s of
  entering the geofence, not the cached state from the previous
  hour.
