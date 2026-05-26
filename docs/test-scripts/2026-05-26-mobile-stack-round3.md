# Mobile stack round 3 — M18 / M19 / M20 / M21 — 2026-05-26

Four mobile items from `docs/test-scripts/2026-05-25-stack.md`. Numbered flat 1–11. Strike passes; reply with net-remaining.

## Wave scope

- **M21** — Safe Mode banner (regression + new always-green design + green action icon badge + chip retirement).
- **M18** — My Workouts empty-state copy revision (3-line list).
- **M19** — Safe Mode HUD toggle moves into existing Diagnostics surface under About.
- **M20** — Clipboard copy animation flying hero originates from LEFT side of card (not the swiped right edge).

## What to test

- [ ] **1.** Inside an enforcing premises without Safe Mode subscription — confirm the persistent banner at the top of the app is **sage green** (`#3DDC97`), full-width, with a 1 px slightly-darker border and a soft sage glow. Headline reads the premises name (e.g. `Manderson Gym`), sub-copy reads `Safe Mode required here — tap to subscribe`, right edge shows a chevron `›`. No orange banner anywhere.

- [ ] **2.** Tap anywhere on the not-subscribed green banner → the Safe Mode paywall sheet opens (premises name appears in the sheet body). Dismiss; the green banner stays.

- [ ] **3.** Subscribe to Safe Mode (or use a pre-subscribed account). Inside the same enforcing premises the banner is still **sage green**, headline still the premises name, sub-copy now reads `Safe Mode active — bystanders blurred`, right edge shows a dark circle with a sage check inside.

- [ ] **4.** Tap the subscribed-active green banner → opens the portal `/safe-mode` page in external Safari (so the practitioner can manage / cancel).

- [ ] **5.** Inside an enforcing premises, the **left-cluster Safe Mode action icon** on Home is a green circular badge (sage fill, sage darker border, soft glow) — irrespective of subscription state (toggle the subscription off and back; the icon stays green either way). Outside the premises (or in manual mode), the action icon falls back to its previous treatment (off = grey shield outline, manual = coral pill).

- [ ] **6.** Manual Safe Mode toggle (long-press the action icon outside any premises) — the green banner appears with headline `Safe Mode` and sub-copy `Manual · bystanders obscured`. Action icon is coral (not green), because manual mode isn't an enforcing-premises promise.

- [ ] **7.** Confirm there is no separate "Subscribe to capture here" compact coral chip anywhere on Home. The widget is retired.

- [ ] **8.** **M18** — open the `My Workouts` tab on a fresh-install or empty account. The empty-state body reads:
  ```
  Record your first workout
  My Workouts is where you:
    • Record workouts to follow back yourself
    • Copy exercises into client sessions
    • Open plans shared with you by other practitioners
  Tap New Session below to start.
  ```
  No "Got a link from your practitioner? Tap to claim it." line.

- [ ] **9.** **M19** — open `Settings`. There is NO top-level "Debug" section anywhere on the screen (no `Show Safe Mode hint overlay` toggle visible by default). Tap the build SHA / Version row at the bottom 7 times — the Diagnostics panel expands and the `Show Safe Mode hint overlay` toggle appears inside it (between the User-ID / Practice-ID / Build-SHA rows and the rest of the panel). Toggle on; re-enter Camera mode; the HUD overlay appears on the viewfinder.

- [ ] **10.** **M20** — open any session in Studio with at least one captured exercise. Long-right-swipe an exercise card to trigger Copy (the long-swipe auto-commit path). The flying hero arc originates from the **LEFT side of the card** (the hero thumbnail position) and arcs up to the clipboard chip in the top-right of the AppBar. It does NOT originate from the right side of the screen where the card was visually shifted during the swipe.

- [ ] **11.** **M20 — partial-swipe path** — right-swipe the card a small amount to reveal the `[Copy] [Duplicate]` actions, then tap `Copy`. The flying hero still originates from the LEFT side of the card's static rest position, not from the swiped position.

## Stack file

This wave closes items M18 / M19 / M20 / M21 from `docs/test-scripts/2026-05-25-stack.md`. Strike them through there as well when each passes.

## Build context

- Branch: `fix/mobile-stack-round3`
- Target: `staging`
- Mobile-only — no portal / web player changes.
- PR title: `fix(mobile-stack-round3): M18 empty-state-copy + M19 hud-toggle-diagnostics + M20 hero-source-rect + M21 safe-mode-banner-green`
