# Handout page loading fix — device QA (2026-05-27)

The workout handout artifact (Wave 1 of artifact-system, /h/{planId})
was stuck on "Loading your plan." indefinitely. Root cause: handout.html
loaded `/api.js` without first loading `/config.js`, so api.js's
strict-fail bootstrap threw at module load and `window.HomefitApi` never
got exported. Same bug also affected me.html, me-data.html, and
what-we-share.html — all four pages are fixed in this PR.

Fix: prepend `<script src="/config.js"></script>` before the api.js
script tag in all four pages.

## Pre-flight

- [ ] Staging is on the post-fix tip. Confirm via the build chip — short
      SHA in the lobby footer when you open any `/p/{planId}` URL on
      `staging.session.homefit.studio`.
- [ ] You have a client with a published plan that has the **handout**
      artifact (PR #549 publish gate writes both Workout plan + Handout
      by default). If not, mint one in mobile: Clients -> open a client
      -> New Session -> 1-2 exercises -> Publish -> tick both kinds.
- [ ] Carl's iPhone CHM is on the matching staging build (the mobile
      side is unchanged in this PR but you need it to navigate from
      Studio into the handout WebView).

## Handout page — direct browser load

- [ ] 1. Open Safari / Chrome / Firefox on desktop or iPhone. Navigate
      to `https://staging.session.homefit.studio/h/<planId>` where
      `<planId>` is the UUID of a plan with the handout artifact
      published. The page renders the full handout content within ~1s:
      header lockup, plan title + practitioner byline, treatment
      toggle, exercise list, footer seal. The "Loading your plan…"
      message disappears.
- [ ] 2. Open the same URL on a plan that does NOT have the handout
      artifact published (or with an invalid plan id like
      `/h/not-a-real-id`). The error card renders: "This plan isn't
      available" with a coral exclamation icon. No stuck loading state.

## Handout page — DevTools console

- [ ] 3. Open `/h/<planId>` with browser DevTools open BEFORE
      navigation. Watch the console. No red errors about
      `window.HOMEFIT_CONFIG missing` or `HomefitApi not loaded`.
      Network tab shows `config.js` returning 200 BEFORE `api.js`
      loads.

## Mobile WebView flow (from Studio)

- [ ] 4. On Carl's iPhone, open the Clients tab -> tap into a client
      that has a published plan with the handout artifact. Expand the
      accordion (per PR #549). Tap the handout artifact card. The
      full-screen WebView opens at `staging.session.homefit.studio/h/{id}`.
      The handout content renders within ~1s — no stuck loading.
- [ ] 5. Tap the back-arrow on the AppBar. Returns to the client
      sessions list with the accordion still expanded.

## /me + /me/data sanity (Wave 2 — same bug pattern, also fixed)

- [ ] 6. Open `https://staging.session.homefit.studio/me` in a
      browser. The sign-in form renders cleanly. Submit your email,
      check inbox, click the magic link. Lands back at `/me` with the
      signed-in plan list painted from `list_my_plans` — no stuck
      loading state.
- [ ] 7. From the signed-in `/me` page, click the "Your data" link
      (or navigate to `/me/data` directly). The preferences page
      renders — no stuck loading state.

## Service-worker cache check

- [ ] 8. On the same browser used for items 1-3, hard-refresh
      (Cmd+Shift+R on macOS, or DevTools -> Application -> Service
      Workers -> Unregister and reload). The page still renders
      correctly. The handout HTML loaded from network has the
      `<script src="/config.js">` tag before `<script src="/api.js">`
      — view-source confirms.

## Regression — /p/{planId} unchanged

- [ ] 9. Open `https://staging.session.homefit.studio/p/<planId>` on
      a known-good plan. The lobby + workout player render normally.
      No new errors in the console. Build chip in lobby footer matches
      the staging tip.

## Print path (handout-specific feature parity)

- [ ] 10. On the rendered handout page, tap the print icon at the
      top-right of the header. The browser's print dialog opens
      against `@media print` styles — claim chip + treatment toggle
      + print button are hidden, exercise list lays out for paper.
      Cancel the dialog.

## Round 2 fix (PR #553) — defensive watchdog + reason chip

The first-round fix in PR #550 added `<script src="/config.js">` to
handout.html, which addresses the api.js module-load throw — but only
on fresh page loads. Carl reported a still-stuck loading state after
force-quitting the iPhone app, suggesting the iOS WKWebView's
per-app HTTP cache was serving the pre-PR-#550 cached `handout.html`
(force-quit does not clear WKWebView's `WKWebsiteDataStore`). This
PR layers three defences so a stale cache (or any future render-time
throw) can never hang the loading dot:

- [ ] 11. **Pre-flight HomefitApi check.** On a fresh `/h/<planId>`
      load (with the new bundle), open DevTools first. Add the line
      `delete window.HomefitApi` to the console **before** the page
      navigates. Refresh. The error card appears almost immediately
      (no 15-second wait), with a small monospace reason chip
      reading "Page failed to initialise. Please reload." A red
      console.error from `[handout]` describes the stale-cache cause.

- [ ] 12. **Load watchdog.** On a fresh `/h/<planId>` load, open
      DevTools → Network → throttling, set to "Offline". Hard-refresh
      the page. Within 15 seconds the error card appears with a
      reason chip "Load took too long. Please check your connection
      and try again." Set throttling back to "Online".

- [ ] 13. **Reason chip on `Plan not found`.** Navigate directly to
      `https://staging.session.homefit.studio/h/00000000-0000-0000-0000-000000000000`
      (a known-invalid plan UUID). The error card appears with a
      reason chip "Plan not found". This is the existing happy-path
      error flow plus the new diagnostic surface — Carl reports a
      bug with a screenshot and the reason chip carries the failure
      mode.

## Round 3 fix (this PR) — root cause (URL cache-busting via `?v={sha}`)

Round 1 (PR #550) fixed the server-side bug — handout.html was loading
api.js before config.js. Round 2 (PR #553) added a defensive watchdog
inside handout.js so the page never hangs indefinitely even if a stale
cached asset returns. Round 3 (this PR) addresses the ROOT CAUSE: iOS
WKWebView's persistent HTTP cache was serving the pre-PR-#550 cached
`handout.html` across app restarts, so practitioners were still seeing
the broken page even after the server fix shipped. The mobile app now
appends `?v={shortSha}` to the handout URL so every new build forces a
fresh fetch of all handout assets.

- [ ] 14. Install the post-fix staging build on Carl's iPhone CHM
      (`install-device.sh staging`). Open Clients → tap a client with
      a published plan that has the handout artifact → expand the
      accordion → tap the handout card. The full-screen WebView opens.
      Confirm via the AppBar long-press peek (or by sniffing the URL
      via Safari Web Inspector → Develop menu → iPhone CHM) that the
      URL is `https://staging.session.homefit.studio/h/<planId>?v=<sha>`
      where `<sha>` matches the build chip in the lobby footer.

- [ ] 15. Force-kill the mobile app, relaunch. Open the same handout
      again. The URL still has the same `?v=<sha>` (build SHA doesn't
      change between launches of the same build) AND the page renders
      cleanly within ~1s. No "Loading your plan…" hang, no watchdog
      fallback chip — fast happy path.

- [ ] 16. On the desktop browser, open
      `https://staging.session.homefit.studio/h/<planId>?v=abc123` (any
      arbitrary value for the v param). The handout still loads
      correctly — the v parameter is ignored by the handout.js path
      regex; it's only there to bust the HTTP cache.

- [ ] 17. Open the handout in Safari on iPhone CHM via the share URL
      (the `/p/<planId>` link copied from Studio toolbar, then change
      `p` to `h` in the address bar). The page renders cleanly. The
      `?v=` param is mobile-only — the canonical share URL still has
      no version suffix (URLs shared via WhatsApp / SMS must stay
      stable across builds).

## What's NOT in this PR

- The `/p/{planId}` (workout-plan) URL stays UNCHANGED. That URL is
  the canonical share URL persisted in `plans.plan_url` and copied
  to clipboard / sent through the share sheet — adding a build-SHA
  cache-buster there would change what's shared on every build,
  breaking URL stability for clients. The iOS app itself never opens
  `/p/{planId}` in a WebView (only Share.share-s it out), so there
  is no WKWebView cache to bust on that path.
- The existing `?v=<plan.version>` cache-bust inside `lobby.js` (web
  player, 2026-05-17) covers per-exercise thumb URLs and is at a
  different layer; this PR doesn't touch it.
