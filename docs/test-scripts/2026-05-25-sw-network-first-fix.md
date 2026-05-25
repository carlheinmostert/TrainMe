# Service worker — network-first + live-page bypass + auto-claim + auto-reload (2026-05-25)

**Branch:** `fix/sw-network-first-and-live-bypass` off `staging`.
**Surface:** Web player only (Vercel project `homefit-web-player`).
**Build verification:** staging deploy SHA visible at the bottom-right footer of any `/p/{id}` page; live page at `/v/{practice}/{premises}/now` runs without a SW intercepting requests.

This wave makes the service worker invisible by construction so the
recurring "shows black again on Safari" pattern stops requiring a manual
comment bump on every `web-player/` PR. Four behaviour changes:

1. The live transparency page is bypassed by the SW entirely — no
   intercepts, no caching.
2. HTML / JS / CSS use network-first across the board so the next reload
   after a deploy gets the new bundle.
3. New SW versions take control on the next event tick (`skipWaiting` +
   `clients.claim`) and pages reload themselves on `controllerchange` —
   the player guards the reload while a workout is mid-rep.
4. `/v/*` paths also get `Cache-Control: no-store` at the Vercel edge as
   belt-and-suspenders.

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Live page bypasses the SW](#a-live-page-bypasses-the-sw)
- [B. HTML is network-first](#b-html-is-network-first)
- [C. New SWs take over and stale tabs reload](#c-new-sws-take-over-and-stale-tabs-reload)
- [D. Lobby still works offline](#d-lobby-still-works-offline)

## Prerequisites

- Vercel preview deploy URL for this PR (look at the PR conversation
  for the bot comment, or fetch from `gh pr view --json statusCheckRollup`).
  Staging URL works once merged: `staging.session.homefit.studio`.
- Safari on macOS with Develop menu enabled (Settings → Advanced →
  "Show features for web developers"). Most of the checks run in the
  Web Inspector's Network and Storage tabs.
- A previously-published staging plan that loads in the lobby + player.
  Any client with at least one exercise on the staging Supabase
  (`vadjvkmldtoeyspyoqbx`) is enough.
- A staging premises with a polygon enforced for Safe Mode, so
  `/v/{practice-slug}/{premises-slug}/now` resolves to the live page
  (not 404). `home-2` under practice `homefit` works at the time of
  writing.

## A. Live page bypasses the SW

- [ ] 1. In Safari, navigate to `staging.session.homefit.studio/p/{any-cached-plan-id}` and let the lobby render. This step exists only to ensure a service worker IS registered on this origin before we check the live page. Confirm in Web Inspector → Storage → Service Workers that a `homefit-player-*` worker is "activated and running".
- [ ] 2. Without clearing storage, navigate the same Safari tab to `staging.session.homefit.studio/v/homefit/home-2/now`. The live page should render: dark hero, Leaflet map with Esri satellite tiles, the polygon outline, and either "0 people are recording right now" or N practitioner avatars depending on real-time state.
- [ ] 3. Open Web Inspector → Network tab. Reload the live page (Cmd+R). For every row in the Network tab (live.html, live.js, config.js, api.js, Leaflet from unpkg, any Supabase REST call, any Esri tile), check the "Source" column — it must NOT show "Service Worker". Document failures with screenshot.
- [ ] 4. Force quit Safari (Cmd+Q) and relaunch. Navigate directly to the live URL. Same Network-tab check: no row should be served by the SW. The bypass applies regardless of which page the user landed on first.

## B. HTML is network-first

- [ ] 5. With Safari already open on a staging lobby URL (`/p/{id}`), confirm a SW is registered (Storage → Service Workers shows `homefit-player-*`).
- [ ] 6. From a terminal in this worktree, make a trivial visible change to `web-player/lobby.js` (e.g. add a `console.log('sw-test-marker');` near the top of `showLobby`), commit on a throwaway branch, push, and wait for the Vercel preview deploy to go green. Note the new preview URL.
- [ ] 7. Back in Safari, reload the staging lobby tab (Cmd+R — a normal reload, NOT Cmd+Shift+R which bypasses the SW). Open Web Inspector → Console. The `sw-test-marker` log should appear on the very first reload — proving lobby.js was fetched from the network, not served from the old cache. Without network-first, the marker would only show after a hard refresh or after closing every tab.
- [ ] 8. Open Web Inspector → Network → Filter "lobby.js". The response Source should show "Service Worker" but the underlying fetch must show a fresh `200` status (look at the headers — Vercel `x-vercel-id` should be new). The SW is wrapping the network response, not replaying a stale cache hit.
- [ ] 9. Throw away the test commit (`git reset --hard origin/staging` or delete the branch) so the marker doesn't ship to staging — this step is a one-off probe.

## C. New SWs take over and stale tabs reload

- [ ] 10. Open a staging lobby tab in Safari and let it idle on the lobby (DO NOT tap "Start Workout" yet). Note the build SHA in the bottom-right chip.
- [ ] 11. Ship a real deploy that changes `web-player/sw.js` byte content (any commit to staging that touches the file works — including the merge of this PR itself). Wait for Vercel to finish.
- [ ] 12. In the lobby tab from step 10, do not reload. Switch to another app (Cmd+Tab), wait ~5 seconds, then switch back. The lobby should auto-reload within a couple of seconds — the build chip in the footer should now show the new SHA.
- [ ] 13. Repeat step 10 but this time tap "Start Workout" and let the timer count down on the first exercise. Trigger another deploy that touches sw.js. While the timer is still running, the page MUST NOT reload — interrupting a rep mid-workout would be a regression.
- [ ] 14. Pause the workout (tap the running timer chip). Within ~1 second of pausing, the page should reload to the new SHA. Same expected outcome if you complete the workout instead of pausing.
- [ ] 15. Open `staging.session.homefit.studio/v/homefit/home-2/now` in a fresh tab BEFORE the new deploy lands. Then deploy a sw.js byte change. Back in the live tab, the reload should fire on next focus / SW takeover. (The live page has no workout-guard so the reload is immediate.)

## D. Lobby still works offline

- [ ] 16. Navigate to `staging.session.homefit.studio/p/{any-cached-plan-id}` in Safari and let it fully load. Tap "Start Workout" and play through one exercise so the videos / thumbnails are cached.
- [ ] 17. Open Web Inspector → Network tab. Use the "Offline" preset under the throttling dropdown (Develop → Network throttling → Offline) to simulate a dead connection.
- [ ] 18. Reload the tab (Cmd+R). The page should still render the lobby. Hero thumbnails should show (from cache). Tap "Start Workout" — the deck should mount and the first exercise's video should play from the cache.
- [ ] 19. Open Network tab. Every cached asset should show "Source: Service Worker" with a green or grey status. No red `(failed)` rows for app-shell files. Supabase REST calls may fail (that's expected — they're network-first with no cache fallback for PII).
- [ ] 20. Turn throttling back to "No throttling" and confirm normal operation resumes.
