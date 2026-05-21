# Checkpoint — 2026-05-17 — Device QA wave: photo B&W, video swap-back warp, the four-layer cache stack, popover containing-block trap

**The day was supposed to be a clean device-QA walk of yesterday's wave. Carl walked items 1 through 6 of the test list and surfaced four separate visible bugs along the way — each diagnosed live via Chrome MCP against the staging lobby, each fixed and shipped same-day. The lessons spiral from one specific symptom (photo PDF rendering colour in B&W mode) into a four-PR cache-strategy unlearning (the lobby's `_thumb.jpg` URLs were never actually immutable, and that assumption had been baked into the service worker since day one) and finally a CSS containing-block trap that put the gear popover 620px off-screen because of an unrelated `backdrop-filter` ancestor.** Seven PRs merged today (eight including the 6-day-old admin-password-reset that Carl decided to land at session close), zero new memory rules, no open PRs at session end. Next session: promote staging → main, smoke prod, TestFlight upload.

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [PR sequence](#pr-sequence)
- [Memory rules added today](#memory-rules-added-today)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Main tip:** `9571dbf` — `docs(checkpoint): 2026-05-16 — full-day rewrite covering 14 PRs + thumb-republish + follow-ups`. Unchanged today; everything went to staging. This commit will be the immediate baseline for the staging → main promotion Carl plans next session.
- **Staging tip:** `0329d12` — `chore(admin): add direct password reset script (bypass email rate limit) (#289)`. Staging contains 8 merges today: #380, #381, #382, #383, #384, #385, #386, #289. The seven content PRs span the morning-evening device QA arc; #289 is the lingering admin utility that landed at session close.
- **iPhone CHM:** still on this morning's `tmp/three-fixes-for-device` build from yesterday's session. Today's wave was entirely web-side fixes — no iPhone reinstall was needed. The web lobby on `staging.session.homefit.studio` carries every fix that mattered for the test list.
- **PR #289 (admin password reset):** merged into staging at `0329d12` today. Was open for 6 days untouched until Carl decided to ship it before the staging → main promotion. Bundles into the next prod release alongside everything else.
- **Vercel staging surfaces:** `staging.session.homefit.studio` auto-deployed each web-touching PR (#380 through #386). Build chip ends at `0329d12`. `staging.manage.homefit.studio` unchanged today — no portal work landed.
- **Device QA results:** items 1, 2, 3, 4, 5 all pass on Mac Safari **and** iPhone Safari after the four-PR cache stack landed. Item 6 (legacy photo backfill, optional) was skipped — Carl judged the wave done.
- **Blocked on Carl (unchanged):** Hostinger 301 redirects (`homefit.studio/privacy|terms` → `manage.homefit.studio/...`); `support@homefit.studio` mailbox; ZA lawyer red-pen of privacy/terms scaffold; PayFast production merchant account.

## The day's big decisions

Four load-bearing decisions today, each a fresh-tip ratification.

1. **Photo B&W must come from baked-greyscale bytes, not a runtime filter.** (PR #381.) Yesterday's PR #377 introduced `_thumb_bw.jpg` (a baked greyscale + 1.05 contrast sibling for photos) and patched `pickPosterSrc` to prefer it for B&W — but missed the symmetric patch to `pickPrimarySrc`, which the lobby actually reads for the `<img src>` attribute. Result: photos in B&W still loaded the raw colour photo as the image source, with the `.is-grayscale` CSS class doing the visual conversion. Live lobby looked correct; PDF export (which html2canvas renders without CSS filters) leaked the underlying colour. The fix is one branch in `pickPrimarySrc` mirroring the existing `pickPosterSrc` ladder. Legacy photos pre-2026-05-16 still fall through to the old colour-plus-CSS path until `backfillMissingVariants` promotes them.

2. **The inactive-video poster needs the same hydrate path as the active video did.** (PR #382.) Carl scrolled past the playing video in the lobby and the row swapped its `<video>` back to a static `<img>` — and the static poster rendered the raw 720×1280 portrait stretched into the 1:1 hero container instead of cropped to the hero offset. Root cause: PR #364 (yesterday) deliberately removed `object-fit: cover` from `img.lobby-hero-media` because the hydrate pipeline was supposed to produce 1:1 data URLs anyway. The swap-back code in `swapToVideoOnActiveRow` was creating the new `<img>` without `data-hero-source` / `data-hero-id` / `data-hero-offset`, so `hydrateHeroCrops` never saw it as a target. Fix: carry the hydrate metadata across the swap-to-video step, attach it to the swap-back `<img>`, call `hydrateHeroCrops()` once after the swap so the resolver re-crops asynchronously. The PR #364 architectural rule is preserved.

3. **The cache strategy was "everything immutable" since day one — and that assumption silently broke when PR #376 made thumbs mutable.** (PRs #383, #384, #385.) Carl moved the Hero star on a video, republished, reloaded Safari — and the lobby kept showing the previous frame. Cloud actually had the new bytes (verified via direct curl + DB `storage.objects.updated_at`), but the URL itself never changed across regenerations. The service worker treated every `.jpg` as cache-first because the original mp4/jpg URLs really were content-addressable. PR #376 introduced `thumbnailsDirty` to re-upload thumbnails on Hero regeneration — same URL, new bytes. The cache layer lied. Three fixes, defence in depth: (PR #383) the SW routes `_thumb*.jpg` through network-first; (PR #384) the SW uses `cache: 'reload'` so the network fetch bypasses the browser HTTP cache layer (Supabase Storage sends `cache-control: public, max-age=3600` — without `reload` the browser still serves stale for an hour); (PR #385, the architectural fix) the lobby appends `?v=<plan.version>` to every thumb URL on render, so each republish gives a fresh URL that misses at every cache layer regardless of strategy. The version-bust alone is sufficient; the SW layers stay as backstop.

4. **`backdrop-filter` is a containing-block-establishing property — `position: fixed` inside it is no longer viewport-relative.** (PR #386.) Carl asked me to demonstrate the gear popover via Chrome MCP and the popover rendered 620px below the viewport, completely invisible to a human. The JS positioning math was correct (top = gear top − gap − popover height = positive in-viewport value); the popover's computed style had the right `top: 379px`; but `getBoundingClientRect` reported the rendered top at 999. The discrepancy: `#lobby-cta-bar` has `backdrop-filter: blur(14px)`, which per CSS spec creates a new containing block for ALL descendants including `position: fixed` ones. The popover's `top: 379px` was relative to the bar (whose viewport top is 619), giving a rendered top of 998. Fix: at open time, move the popover element to `document.body`, where no ancestor has containing-block-creating styles, so `position: fixed` resolves viewport-relative as the algorithm assumed. The same trap applies to `transform`, `filter`, `perspective`, `contain` — `backdrop-filter` is just the entrant we hadn't tripped on yet.

## PR sequence

| # | PR | Title | Why |
|---|---|---|---|
| 1 | [#380](https://github.com/carlheinmostert/TrainMe/pull/380) | `docs(test-scripts): add 2026-05-17 publish-flow refactor smoke` | Test script for yesterday's PR #379 publish-flow refactor. Promoted to top of "test these now". Walks in tandem with the two PR-specific scripts from yesterday. |
| 2 | [#381](https://github.com/carlheinmostert/TrainMe/pull/381) | `fix(player): photo B&W uses _thumb_bw.jpg as primary src so PDF export honours it` | Surfaced live by Carl walking item 3 (PDF B&W). PR #377 patched `pickPosterSrc` but missed `pickPrimarySrc`; the `<img src>` was still the raw colour photo with CSS filter masking it on the live lobby. |
| 3 | [#382](https://github.com/carlheinmostert/TrainMe/pull/382) | `fix(player): video swap-back re-hydrates so poster crops to 1:1` | Carl scrolled past the active video; the swap-back `<img>` had no `data-hero-source`, so `hydrateHeroCrops` skipped it and the raw 720×1280 portrait stretched into the 1:1 container under default `object-fit: fill`. |
| 4 | [#383](https://github.com/carlheinmostert/TrainMe/pull/383) | `fix(sw): network-first for _thumb*.jpg so Hero-drag republish renders` | First attempt at the cache bug. Routed mutable thumb URLs through network-first instead of cache-first. Insufficient on its own — `fetch(request)` still respects browser HTTP cache. |
| 5 | [#384](https://github.com/carlheinmostert/TrainMe/pull/384) | `fix(sw): force cache:reload on thumb fetches to bypass max-age=3600` | Second attempt. New `networkRevalidateStrategy` constructs a fresh `Request` with `cache: 'reload'` so the network fetch ignores the browser HTTP cache layer too. Still insufficient — page-load race meant the SW wasn't always active before the first hydrate ran. |
| 6 | [#385](https://github.com/carlheinmostert/TrainMe/pull/385) | `fix(lobby): version-bust thumb URLs so Hero-drag republish renders` | The architectural fix. Lobby appends `?v=<plan.version>` to thumb URLs at render time. Each republish bumps version → new URL → cache miss at every layer. Race-immune. PRs #383 + #384 stay in place as defence in depth. |
| 7 | [#386](https://github.com/carlheinmostert/TrainMe/pull/386) | `fix(lobby): settings popover escapes backdrop-filter containing block` | Discovered when Carl asked me to operate the gear via Chrome MCP. `#lobby-cta-bar`'s `backdrop-filter` was rerouting the popover's `position: fixed` coordinates relative to the bar instead of the viewport. Fix: move popover to `document.body` at open time. |
| 8 | [#289](https://github.com/carlheinmostert/TrainMe/pull/289) | `chore(admin): add direct password reset script (bypass email rate limit)` | Lingering 6 days. Carl decided to ship it before the staging → main promotion. Pure admin utility — no app or lobby code changed. |

## Memory rules added today

None. Today's bugs were all instances of patterns already covered (`feedback_no_exception_control_flow`, the existing service-worker memory entries, the hero-resolver single-source-of-truth rule). The four cache PRs together arguably warrant a dedicated "URL is the cache key — mutable bytes need a mutable URL" memory entry; defer to the next session to decide if it's worth its own file.

## Open follow-ups for next session

1. **Promote staging → main.** Use the `homefit-promote-staging-to-main` skill. Draft the release-promotion PR (will list the eight PRs landed today), run pre-merge sanity, stop before merge. Carl explicitly promotes.

2. **Smoke test prod env.** After staging → main lands and Vercel deploys, verify the prod env variables resolve correctly: `session.homefit.studio` lobby renders, `manage.homefit.studio` portal signs in, audit log + credit balance + client list all populate, embedded preview opens. Spot-check via Chrome MCP if needed.

3. **Deploy to TestFlight.** Bump `pubspec.yaml` build number, archive via `xcodebuild`, upload via Transporter. Per `docs/TESTFLIGHT_PREP.md`. Bundle ID is `studio.homefit.app`; last TestFlight upload was 2026-05-05 (build SHA `f6f7bce`) per the project overview memory.

4. **Memory entry for the cache lesson.** Optional but probably worth it: a short `gotcha_mutable_url_needs_mutable_key.md` or similar capturing "the moment a URL's bytes can change without the URL changing, every cache layer along the path is lying about freshness — bust at URL level or accept staleness". Pin to PR #376 + #385 as the source incident.

5. **Item 6 from today's test list.** Optional legacy photo backfill walk on Carl's iPhone — only needed if photos captured pre-2026-05-16 start surfacing as colour in B&W mode. The published-plan inventory on staging is small enough that organic re-publish probably covers most cases.

## Lessons / gotchas

- **A bug whose symptom is "PDF renders colour" can have its root cause four layers deep.** Carl thought he was reporting one bug (PDF colour in B&W mode). The investigation surfaced: photo primary src wrong (PR #381), video swap-back warp (PR #382), three layers of cache lying (PRs #383 / #384 / #385), and a CSS containing-block trap (PR #386). All distinct, all visible in the same lobby session, each diagnosed in the order Carl tripped on it. The discipline of "fix exactly the thing the user reported, then ask what's next" surfaced each one cleanly without scope creep.

- **`backdrop-filter` joins `transform` + `filter` + `perspective` + `contain` in the containing-block-establishing club.** Any descendant with `position: fixed` inside a `backdrop-filter` ancestor is no longer viewport-relative. The safe pattern: when you need true viewport-relative positioning, move the element to `document.body` at use time. The popover code was doing the right algorithmic thing — the architecture was the lie.

- **Defence in depth is correct when the bug is a leaky abstraction.** The cache strategy bug needed three PRs (SW network-first, SW cache:reload, URL versioning) because each layer's cache is technically correct under its own contract — they're all honouring `cache-control: public, max-age=3600`. The fix isn't to change the contract; it's to make the URL change. Once the URL changes, every layer behaves correctly without coordination. PRs #383 + #384 are belt-and-braces; PR #385 is the spine.

- **`fetch(request)` respects browser HTTP cache by default — pass `cache: 'reload'` to bypass it.** Service worker network-first isn't actually network-first if the browser HTTP cache layer serves stale content first. The `Request` object's cache mode is read-only after construction, so the SW has to build a new `Request` with the cache override before fetching.

- **`offsetWidth > 0 && offsetHeight > 0` is a lie about visibility.** An element can have computed dimensions and a non-`hidden` ancestor chain but still render entirely outside the viewport. The honest visibility check is `getBoundingClientRect().bottom <= window.innerHeight && rect.top >= 0` etc. Worth a one-liner in the chrome-mcp toolkit if I find myself asserting "visible" again.

- **`get_plan_full` is the right place to bump cache keys, but client-side is faster to ship.** The architectural fix could go in `get_plan_full` (server-side append of `?v=<version>` to thumb URLs). I chose client-side (append in `showLobby`) to skip the Supabase migration round-trip. Both work; the client-side version makes the iOS embedded preview's separate path automatically immune (since it doesn't pass through `showLobby`). A future tightening could move the buster to the migration so every consumer gets it for free.

## Fresh-session handoff

**READ FIRST:** this file (`docs/CHECKPOINT_2026-05-17.md`). The staging tip is `0329d12`. Main tip is unchanged at `9571dbf` (yesterday's checkpoint commit). Carl's next-session plan is: (1) promote staging → main via the `homefit-promote-staging-to-main` skill, (2) smoke test prod's env-variable resolution after Vercel deploys main, (3) deploy to TestFlight (first since 2026-05-05).

**Carl's iPhone is still on yesterday's `tmp/three-fixes-for-device` build** — no reinstall happened today because every fix was web-side. If anything publish-related or studio-side breaks during the staging → main promotion, the staging build that's verified today is `0329d12`; install via `./install-device.sh staging`.

**The cache strategy is now defence-in-depth.** Lobby appends `?v=<plan.version>` to thumb URLs (PR #385 — the spine); the SW routes `_thumb*.jpg` through network-first (PR #383) and uses `cache: 'reload'` to bypass browser HTTP cache (PR #384). If anything cache-related surfaces, check via Chrome MCP whether the URL on screen has the version query string AND whether the SW is intercepting before assuming the bytes are wrong. The first hardware reload on each device needs to clear the OLD SW once for the new chain to take over; after that, normal reload propagates.

**The `backdrop-filter` containing-block lesson generalises.** Anywhere we use `position: fixed` on a descendant of an element with `transform`, `filter`, `perspective`, `contain`, or `backdrop-filter`, the descendant is no longer viewport-relative. If a "centred" or "anchored" element ever renders off-screen for no apparent reason, walk the ancestor chain looking for these properties. The fix shape is the same as PR #386: move the floating element to `document.body` at use time.
