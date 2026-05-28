# Handout "Loading your plan" hang — true root cause (CSS) — device QA (2026-05-28)

The workout handout (`/h/{planId}` + the Studio Preview -> "Workout
handout" LOCAL preview) was stuck on "Loading your plan…" forever. Three
prior rounds (PR #550 config.js ordering, PR #553 watchdog, the `?v={sha}`
cache-bust) all missed — the JavaScript was working the whole time.

**Real root cause:** `handout.css` set `display: flex` on the
`.handout-loading` / `.handout-page` / `.handout-error` containers. Those
containers are toggled in JS via the global `hidden` HTML attribute
(`$loading.hidden = true`). But an author `display` rule always beats the
user-agent stylesheet's `[hidden] { display: none }` (author origin wins
over UA origin), so `hidden = true` had NO visual effect. The loading
overlay (`position: fixed; inset: 0; z-index: 100`) stayed painted on top
of the fully-rendered page forever.

Captured runtime evidence (iOS simulator, custom-scheme local preview):
`render()` ran to completion, the fetch returned 200, the plan + 1
exercise were parsed — yet "Loading your plan…" still showed. Confirmed it
was a CSS overlay, not a JS hang.

**Fix:** one rule in `handout.css` — `[hidden] { display: none !important; }`
— restores the intended semantics of the `hidden` attribute so the JS
toggles take effect. No JS / Swift / bridge change.

## Pre-flight

- [ ] Build is the post-fix staging tip. Confirm via the build chip —
      short SHA on the Home `HomefitLogo` (mobile) or the lobby footer
      (web).
- [ ] You have a client with a published plan that has at least one
      exercise. If not, mint one: Clients -> open a client -> New Session
      -> add 1-2 exercises -> Publish.

## Mobile — Studio LOCAL preview (the reported repro)

- [ ] 1. On Carl's iPhone CHM, open Clients -> tap a client -> open a
      session in Studio. Tap **Preview** (CAPS toolbar). In the picker,
      tap **Workout handout**. The full-screen WebView opens and renders
      the full handout within ~1s — header lockup, plan title, treatment
      toggle (Line / B&W / Original), the exercise list, and the footer
      seal. The "Loading your plan…" message is GONE.
- [ ] 2. Tap the back-arrow. Returns to Studio cleanly. Re-open Preview
      -> Workout handout a second time — still renders fast, no hang.
- [ ] 3. In the same handout preview, tap the print icon (top-right of
      the header). The iOS print dialog opens; claim chip + treatment
      toggle + print button are hidden in the print layout. Cancel.

## Web — remote handout (same CSS, same fix)

- [ ] 4. On desktop Safari / Chrome / Firefox, open
      `https://staging.session.homefit.studio/h/<planId>` for a plan with
      a published handout. Renders the full handout within ~1s. No stuck
      loading overlay.
- [ ] 5. Open `https://staging.session.homefit.studio/h/not-a-real-id`
      (invalid id). The error card renders ("This plan isn't available")
      — NOT a stuck loading state. Confirms the error path also un-hides
      correctly now that `[hidden]` is honoured.
- [ ] 6. On the rendered web handout, switch the treatment toggle between
      Line / B&W / Original (whichever are unlocked by consent). The
      exercise list re-renders each time — no flash of the loading
      overlay.

## Regression — workout player + /me unchanged

- [ ] 7. Open `https://staging.session.homefit.studio/p/<planId>` for a
      known-good plan. The lobby + workout player render normally. (The
      `[hidden]` reset is scoped to `handout.css` only — the player uses
      `styles.css`, untouched.)
- [ ] 8. From Studio Preview, choose **Workout player** (not handout).
      The card-deck preview opens and plays as before — no regression
      from the handout fix.

## What's in this PR

- `web-player/handout.css` — the single `[hidden] { display: none
  !important; }` rule (+ explanatory comment).
- `app/assets/web-player/handout.css` — R-10 bundle mirror (byte-identical).
- No JavaScript, Swift, or Dart change. The prior watchdog (PR #553) and
  `?v={sha}` cache-bust (round 3) stay in place as defence-in-depth.
