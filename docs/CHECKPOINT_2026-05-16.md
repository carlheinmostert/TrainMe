# Checkpoint — 2026-05-16 — Publish unblocked, diagnostic surfaces work, SW network-first, hero crop two-part fix

**A full-day session that started with the circuit-animation saga ending (attempt #10 verified on iPhone), grew a diagnostic surface that became the keystone for everything after, hit a 24-hour staging-publish outage at 11:00 UTC traced to a Supabase storage RLS regression introduced by yesterday's `upsert: true` flip, got unblocked via a new SELECT-policy migration, then propagated through an architectural fix to the diagnostic tap-dead bug, two PDF rendering fixes (greyscale bake + active-row `<video>` swap), a service-worker network-first switch to fix the production cache-update story, the long-press regression fix with the Replace pill, the hero-crop auto-pick from segmentation + manual drag, and finally the thumb-republish-on-regen fix that unsticks already-published exercises whose hero offsets the practitioner has since adjusted.** 14 PRs merged today, 1 (PR #376) open and ready to merge, 1 new gotcha memory rule, 1 lingering bug surfaced for the next session (photo `_thumb_bw.jpg` baked-bytes proper fix per the "no fallback" rule).

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [PR sequence](#pr-sequence)
- [Memory rules added today](#memory-rules-added-today)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Main tip:** `db2a27e` — `docs: add studio toolbar cleanup mockup + device QA test script (PR #371)`. Today's morning-checkpoint commit (the first version of this file, capturing only the morning's work) was rolled forward into this comprehensive end-of-day version.
- **Staging tip:** `b6d8aed` — `chore(web-player): drop stale PLAYER_VERSION constant — gitSha is source of truth (#373)`. Staging contains 14 merges today: #362, #363, #364, #365, #366, #367, #368, #369, #370, #371, #372, #373, #374, #375.
- **iPhone CHM:** still on the morning's `tmp/three-fixes-for-device` combined-branch build (~12:00 UTC install). That binary has PRs #366, #367, #368 baked in; the afternoon's #370, #372, #375 are NOT in the iPhone build yet. The next install (`./install-device.sh staging`) will land everything plus the in-flight PR #376 once merged.
- **PR #376 (thumb-republish):** open, ready to merge after Carl reviews. THE fix for "Hero drag in Demo tab doesn't actually update the lobby thumbnail" — the publish fast-path was skipping thumb re-uploads when `rawArchiveUploadedAt` was already stamped. Adds a local `thumbnailsDirty` flag (SQLite v40) set by `regenerateHeroThumbnails`, honoured by publish, cleared on success.
- **PR #289 (admin password-reset):** still open 6 days, untouched today, retargeted to staging earlier.
- **Vercel staging surfaces:** `staging.session.homefit.studio` auto-deployed every web-touching PR. Latest serves `gitSha: b6d8aed`. `staging.manage.homefit.studio` unchanged today.
- **Blocked on Carl (unchanged):** Hostinger 301 redirects (`homefit.studio/privacy|terms` → `manage.homefit.studio/...`); `support@homefit.studio` mailbox; ZA lawyer red-pen of privacy/terms scaffold; PayFast production merchant account.

## The day's big decisions

Five load-bearing decisions today.

1. **The hero crop is shared logic; it lives in ONE resolver, never inline.** (Morning carry-over from PR #364.) Five surfaces used to each do crop math themselves; the PDF squashed portraits because html2canvas ignores `object-fit: cover`. PR #364 centralised the web side; three enforcement layers landed alongside (spec doc, memory rule, CI grep rule). Flutter consumers tracked in BACKLOG.

2. **Diagnostic surfaces are the keystone, but they cannot themselves be tap-dead.** (PR #366.) The diagnostic surface PR #362 added in the morning was supposed to let Carl read the publish-failure file list. By 12:00 UTC he discovered the "Show which files →" tap fired the haptic but never opened the sheet — third occurrence of the same modal-stacking bug class (PRs #357 + #362 had already tried to patch it via `useRootNavigator` flips). PR #366 took the architectural exit per `superpowers:systematic-debugging`'s "fix #3 = question the architecture" rule: no second modal at all. `PublishProgressSheet` owns an internal view-state (`progress` / `failureDetail` / `errorDetail`) and swaps its body. One modal route, no navigator-scope guesswork, the bug class is gone.

3. **Raw-archive RLS needs an owner-scoped SELECT policy when uploads use `upsert: true`.** (PR #369.) This was the major blocker of the day. Yesterday's PR #358 flipped raw-archive uploads to `upsert: true` to eliminate 409 Duplicate exceptions on re-publish — per the no-exception-control-flow rule. Side effect surfaced today: Supabase Storage's upsert path needs the row to be SELECT-readable so it can decide INSERT vs UPDATE before WITH CHECK fires. The raw-archive bucket previously blocked SELECT entirely (privacy model: signed URLs only). Result: zero raw-archive uploads landed on staging from 2026-05-15 14:50 UTC onwards; 155 succeeded in the 3 days before. We diagnosed the symptom via the now-working inline diagnostic surface (PR #366) → storage logs gave us PG 42501 from `ExecWithCheckOptions` → policy gap confirmed via `pg_policies`. PR #369 adds `Raw-archive owner select` policy scoped to `owner = auth.uid()`. Privacy model preserved: anon still no SELECT, authenticated SELECT own only, service_role unchanged. New gotcha memory entry captures this whole class of bug for the next time.

4. **Service worker app shell must be network-first, not cache-first, for production cache-update behaviour.** (PR #372.) Carl hit this the hard way after PR #370 deployed: his iPhone Safari kept serving an older `v70-png-modal-removed` bundle through multiple reloads + Private Browsing. Root cause: the SW routed the entire app shell through `cacheFirstStrategy`. Even with `skipWaiting` + `clients.claim` correctly wired, the current page held old JS in memory; Safari's HTTP cache amplified it. PR #372 splits the routing: Supabase API stays network-first, media (immutable URLs) stays cache-first, but app shell (HTML / JS / CSS / config) switches to network-first with cache fallback for offline. Cost: ~50–200ms per asset on cold reload. Future deploys propagate on a single reload. Each browser still needs ONE manual cache-clear hop to break out of the old cache-first SW; after that, automatic forever.

5. **Hero crop has two valid sources of truth: segmentation-centroid auto-pick + manual drag override.** (PR #375.) The default crop offset (0.5 — geometric centre vertical band of a portrait video frame) routinely catches whatever's in the middle (a TV in the background, in Carl's test case). Two-part fix. (a) Native Swift computes the person mask's vertical centroid during the existing segmentation pass and seeds `hero_crop_offset` automatically. (b) The manual drag override (`HeroCropViewport`) was discovered to be already shipped in code — verified end-to-end via DB write inspection. Manual drag overrides auto-pick; re-scrubbing the temporal hero frame re-runs auto-pick on the new frame (destructive — simpler than tracking auto-vs-manual separately).

## PR sequence

In merge order across the day:

| # | PR | Title | Why |
|---|---|---|---|
| 1 | [#362](https://github.com/carlheinmostert/TrainMe/pull/362) | `fix(publish): diagnostic surface for non-atomic upload failures + atomic media-bucket uploads` | Morning carry-over. The diagnostic surface that EVERY subsequent debug today relied on. |
| 2 | [#363](https://github.com/carlheinmostert/TrainMe/pull/363) | `chore(schema): add practice_id column to local sessions table (DB v39)` | SQLite mirror bump, direct-to-main. |
| 3 | [#364](https://github.com/carlheinmostert/TrainMe/pull/364) | `refactor(player): centralise hero-crop resolution + fix PDF object-fit bug` | New `web-player/hero_resolver.js` + PDF portrait-squash fix as side effect. |
| 4 | [#365](https://github.com/carlheinmostert/TrainMe/pull/365) | `chore(ci): enforce hero-resolver single-source-of-truth rule` | Forbids inline crop math via grep rule in custom-rules CI job. |
| 5 | [#366](https://github.com/carlheinmostert/TrainMe/pull/366) | `fix(publish): inline diagnostic views — kill modal-stacking tap-dead` | Architectural fix at attempt #3 — no second modal, body swap inside the parent sheet. |
| 6 | [#367](https://github.com/carlheinmostert/TrainMe/pull/367) | `fix(studio): restore long-press drag-to-reorder + Replace pill on Demo surface` | Carl's regression from yesterday. Long-press drops back to reorder; Replace becomes a labelled coral pill. |
| 7 | [#368](https://github.com/carlheinmostert/TrainMe/pull/368) | `fix(player): bake bw treatment into resolver bitmap so PDF export honours it` | Canvas `ctx.filter = grayscale(1) contrast(1.05)` baked into the cropped data URL. Discovered to have a WKWebView edge case for photos in B&W (see follow-ups). |
| 8 | [#369](https://github.com/carlheinmostert/TrainMe/pull/369) | `fix(supabase): owner-scoped SELECT on raw-archive so upsert: true works` | THE big unblocker. Applied to staging Supabase directly, PR for the durable record + prod promotion. |
| 9 | [#370](https://github.com/carlheinmostert/TrainMe/pull/370) | `fix(lobby): swap <video> to <img> in PDF export so active row isn't grey-blocked` | html2canvas can't reliably rasterise a `<video>` element; export builder swaps to `<img>` using the cropped data-URL poster. |
| 10 | [#371](https://github.com/carlheinmostert/TrainMe/pull/371) | `feat: clean up studio toolbar — drop separators, strip glyph chip, refresh adjust icon` | Carl-authored toolbar polish wave; landed in parallel with the bug-fix chain. |
| 11 | [#372](https://github.com/carlheinmostert/TrainMe/pull/372) | `fix(sw): network-first for app shell so new deploys propagate on reload` | Production-grade cache-update story. App shell → network-first; media → cache-first (unchanged). |
| 12 | [#373](https://github.com/carlheinmostert/TrainMe/pull/373) | `chore(web-player): drop stale PLAYER_VERSION constant — gitSha is source of truth` | The `v70-png-modal-removed` hand-coded constant misled QA for 30+ min today; the chip now reads `{sha} · {branch} · cache {sha}` cleanly. |
| 13 | [#374](https://github.com/carlheinmostert/TrainMe/pull/374) | `chore: set up agent-friendly simulator auth (test account + keep-auth script)` | QA tooling so agents can act on the simulator without a manual sign-in. |
| 14 | [#375](https://github.com/carlheinmostert/TrainMe/pull/375) | `feat(hero): auto-pick crop offset from segmentation + Demo-tab drag override` | Swift centroid math + Dart wiring. Manual drag UI confirmed already shipped. |
| ☐  | [#376](https://github.com/carlheinmostert/TrainMe/pull/376) | `fix(publish): re-upload regenerated thumbnails so hero drag lands` | **OPEN — ready for Carl's review.** Local-only `thumbnailsDirty` flag (SQLite v40) closes the stale-cloud-thumb loop after a regeneration. |

## Memory rules added today

- [Supabase Storage `upsert: true` needs SELECT visibility](../../../../Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_supabase_storage_upsert_needs_select.md) — A SELECT-blocked private bucket + `upsert: true` = every upload fails RLS WITH CHECK with PG 42501. Add owner-scoped SELECT policy (`owner = auth.uid()`) so the storage service can do its internal existence check. Cost: 24h of broken staging (PR #358 → PR #369). Index entry stamps the relationship to the no-exception-control-flow rule that motivated `upsert: true`.

## Open follow-ups for next session

1. **Merge PR #376 + install + close out today's QA.** Once merged, run `./install-device.sh staging` on Carl's iPhone. Re-drag the hero on the existing stuck video exercise → re-publish → lobby should reflect the new crop within seconds. That closes the diagnostic loop on today's blocking bug.

2. **Photo `_thumb_bw.jpg` baked-bytes proper fix (per the no-fallback rule).** Surfaced late in the session: the embedded preview's PDF renders the photo's B&W treatment as colour. Architectural diagnosis: videos in B&W use baked-greyscale bytes (`_thumb.jpg` from the iOS converter's segmentation pipeline) while photos in B&W use a colour JPG + CSS / canvas filter. Different mechanisms for the same logical treatment violates the "one treatment, one artifact" rule. The proper fix is to generate `_thumb_bw.jpg` at photo capture time (greyscale bytes baked in), matching the video pattern. Spans iOS photo handler, SQLite migration, upload service, Supabase schema, `get_plan_full` RPC, `pickPosterSrc` in `exercise_hero.js`, embedded scheme bridge, plus a backfill path for existing photos. Half-day agent work — should be the first task in the next session.

3. **Two BACKLOG observations from the thumb-republish agent's read-through.** (a) The segmented `.segmented.mp4` / `.segmented.jpg` and mask `.mask.mp4` variants have no `rawArchiveUploadedAt`-equivalent tracking column; if regenerated post-conversion they'd be skipped by the listing existence check. Same class as PR #376 but lower impact (variants rarely change). (b) `_isUserContentDelta` ignores `focusFrameOffsetMs` and `heroCropOffset` — hero-tuning edits don't extend the structural-edit lock window. Likely intentional but worth confirming.

4. **Flutter hero-resolver migration.** Still in BACKLOG (carry-over from PR #364). The 5 Flutter consumers (Studio card, filmstrip cell, camera peek, editor sheet, plan preview) do their own `Alignment` math against `exercise.heroCropOffset` instead of routing through the centralised resolver. Out of scope today.

5. **Worktree cleanup.** 120+ agent worktrees alive at session start; today's session added ~7 more before cleanup. The `homefit-cleanup-worktrees` skill exists for this. Worth a sweep before the next big wave.

## Lessons / gotchas

- **The diagnostic surface is the keystone — without it, debugging publish failures is blind.** PR #362 enabled today's diagnosis of PR #369 (the storage policy gap). Every subsequent fix today traces back to "we could finally see the actual error."

- **Architectural fixes win at attempt #3.** Two patch attempts (PR #357, PR #362) on the diagnostic tap-dead bug both papered over the navigator-scope mismatch without resolving it. PR #366 dropped the second-modal pattern entirely — bug class gone, not patched. The `superpowers:systematic-debugging` Phase 4.5 rule about "question the architecture at fix #3" is load-bearing.

- **Supabase Storage `upsert: true` needs SELECT visibility.** Captured as a gotcha memory. The non-obvious bit: the SDK call has been the same for weeks; the schema policies have been the same since PR #354 recovered them. The bug only surfaced because `upsert: true` triggers an `INSERT ... ON CONFLICT DO UPDATE RETURNING *` SQL path that the storage service has to introspect — and the introspection needs SELECT. Without it, the WITH CHECK denies before the row even tries to land.

- **Service worker cache-first for app shell is production-broken.** Even with correct `skipWaiting` + `clients.claim`, the current page holds old JS in memory; Safari's HTTP cache amplifies it. Production needs network-first for the app shell — accept the 50-200ms cold-reload penalty in exchange for guaranteed deploy propagation.

- **PLAYER_VERSION static constants drift; git SHA is the single source of truth.** The hand-coded `v70-png-modal-removed` label misled QA today for ~30 min. Git SHA + branch + active SW cache name are the durable signals.

- **Embedded WebView ≠ Safari for canvas features.** `ctx.filter` behaved differently in the in-app preview WebView vs Safari proper. The "no fallback" rule says don't depend on runtime filters that may vary by surface; bake the desired bytes at conversion time. This is the architectural argument for the photo `_thumb_bw.jpg` follow-up.

- **The stale-cloud-thumb loop is not about caching at all — it's about the publish fast-path skipping re-uploads.** Carl re-published 6 times today; the cloud thumb mtime stayed at the morning's first publish. Diagnosed by curl'ing the file directly (15054 bytes / 171×192 px = autoPick=true tight crop, NOT the user-selected hero frame). PR #376 adds a `thumbnailsDirty` local-only flag so the fast-path is broken correctly when local thumbs have regenerated.

## Fresh-session handoff

**READ FIRST:** this file (`docs/CHECKPOINT_2026-05-16.md`). It supersedes the morning's version of the same filename (which captured only PRs #361–#365 + skills + memory; today's afternoon added 9 more merges + a sixth memory entry + a major lingering follow-up).

**Carl's iPhone is still on the morning's `tmp/three-fixes-for-device` build** (with PRs #366 + #367 + #368 baked in but NOT PR #370 / #372 / #375). The first task in the next session should be: merge PR #376, then `./install-device.sh staging` to bring the iPhone up to current staging tip.

**The big lingering bug is the photo `_thumb_bw.jpg` baked-bytes proper fix.** Diagnosed but not implemented today — too risky to tack on at end-of-day given the file overlap with the in-flight thumb-republish agent. Brief is in follow-up #2 above. The "tactical per-pixel ImageData filter" workaround was offered and declined in favour of the proper fix.

**Staging is at `b6d8aed`** which carries all of today's merges. Vercel staging surfaces are auto-deployed and serving fresh. Carl's Safari + Chrome were caught in the v70-cache-first SW trap earlier today; after the one-time Settings → Privacy → Manage Website Data clear (Safari) or `chrome://serviceworker-internals/` unregister (Chrome) hop, the new SW (PR #372) takes over with network-first behaviour for all future deploys.

**The diagnostic surface (PR #362 + PR #366) is the keystone tool.** If anything publish-related breaks in the next session, the first move is: tap "Show which files →" or "Show error details →" on the failure sheet — that body-swap view inside the progress sheet exposes the actual exception path. From there, every Phase 1 debug question reduces to "which file kind failed and what HTTP / PG code did the server send."
