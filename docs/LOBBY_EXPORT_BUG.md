# Lobby PNG Export — Unsolved (2026-05-05)

**Status:** Open. 11 rounds of attempts (PRs #265 → #275, player versions v59 → v69) on 2026-05-05 did not produce a working desktop export. Carl moved on; this is the handoff for next week.

## Goal

Add a "Share" button to the lobby (next to the gear, on `session.homefit.studio/p/{planId}`) that snapshots the lobby as a PNG and lets the user save / share it.

## Current state on `main` (v69)

- Click share → in-page modal opens immediately with "Generating preview…" spinner.
- html2canvas snapshots the lobby; modal swaps to either the rendered PNG + Download button or a coral error message.
- **Carl has not confirmed v69 works.** He gave up and asked for documentation before testing it.
- Mobile path (iPhone Safari, iPad, Android) uses `navigator.share({ files })` — that worked in earlier rounds. Untouched in v69.

## What worked

- **Mobile share sheet via `navigator.share` (item 5 PASS as of v66).** iPhone Safari opens the iOS share sheet with the rendered PNG. Don't break this.
- **Modal infrastructure.** The self-injecting modal builder (lobby.js `ensureExportModal`) renders fine. Carl confirmed seeing the modal when error messages were surfaced.
- **CORS pre-fetch via fetch + FileReader → data URL.** Supabase responds with `Access-Control-Allow-Origin: *` for both the public `media` bucket and signed `raw-archive` URLs. The pre-fetch successfully converts every lobby image to a base64 data URL.

## What didn't work, by round

Each round shipped a fix for the previous round's symptom; each new fix exposed a new failure mode underneath.

| Round | PR | Approach | Symptom Carl reported |
|------:|----|----------|------------------------|
| 1 | #265 (v59) | `<a href={blobUrl} download>` programmatic click | Page navigated to the PNG (replaced current page). User-activation lost across the async snapshot chain. |
| 2 | #266 (v60) | Existence-check thumb URLs in `get_plan_full` | Fixed broken-image glyphs on inactive thumbs (separate issue). Still wrong nav on share. |
| 3 | #267 (v61) | Pre-open `window.open('about:blank')` synchronously in click handler | Popup blocker on macOS Safari/Chrome silently blocked the popup. |
| 4 | #268 (v62) | In-page modal with real Download anchor (modal markup in index.html) | "about:blank page is opened in new tab" — service worker cached old index.html (no modal block) alongside new lobby.js (calling `getElementById`). Fell back to `<a target="_blank">` which opened blob in new tab. |
| 5 | #269 (v63) | Self-injecting modal in JS (no dependency on cached HTML) | "Bottom bar disappears, no modal, no nothing." `canvas.toBlob` returned `null` silently because the canvas was tainted. Click-handler `.catch()` swallowed the throw. |
| 6 | #270 (v64) | Pre-fetch images via `fetch(mode:'cors')` → blob → swap in `onclone` | "Couldn't generate the image" error appeared (so the modal works) but `toBlob` still returned null. The `onclone` swap doesn't actually re-fetch in html2canvas — by the time `onclone` fires, the resource loader has already cached the original cross-origin imgs. |
| 7 | #271 (v65) | Live-DOM blob-URL swap with `await img.complete` | "Last exercise shows a question mark" during snapshot. Swapping `img.src` to a `blob:` URL triggers a fresh fetch; during the in-flight gap, the broken-image glyph shows. |
| 8 | #272 (v66) | Data URLs (base64-inlined) swapped in `onclone` | **macOS native share sheet opened** with the rendered PNG, but **pictures were missing**. html2canvas's resource loader runs DURING the clone phase, before `onclone` fires — src changes in onclone don't re-trigger loading, so the renderer rasterized empty image slots. Carl said this was "more of the behavior I would expect — a share sheet, not a custom modal." |
| 9 | #273 (v67) | Hidden clone with data URLs + `await img.decode()` | All-black PNG. `visibility: hidden` on the clone container cascaded through html2canvas's render — it respects visibility and drew only the background color. |
| 10 | #274 (v68) | Live-DOM data-URL swap + `await img.decode()`, allowTaint:false | "Page changes to print layout, toolbar changes, no popup at all." Snapshot completed silently; either `navigator.share` hung (lost user-activation), `canvas.toBlob` returned null without error, or html2canvas threw and was swallowed. Couldn't determine which. |
| 11 | #275 (v69) | Modal-first UX: spinner on click, swap to PNG/error, desktop drops `navigator.share` entirely | **Untested by Carl.** Should at minimum guarantee the user always sees the modal — but the underlying snapshot may still be broken in ways round-10 was. |

## The closest-to-working version: v66

In v66, the macOS share sheet **opened** with a rendered PNG. The PNG had layout but missing thumbnails. That's a 1-line-fix away from "done" — we just need to get html2canvas to render the swapped images.

The block: html2canvas v1.4.1's resource loader runs synchronously during the clone phase, before `onclone` fires. Swapping `img.src` in onclone doesn't trigger a re-fetch, so the renderer paints empty boxes for those imgs.

## Suggested next steps when picking back up

In rough order of likely-to-work:

1. **Revert to v66 approach + add `crossorigin="anonymous"` to the original `<img>` tags in `lobby.js`** (in `renderHeroHTML` and any other place imgs are emitted). After a hard-refresh, the imgs load CORS-clean from the start. html2canvas's resource loader fetches with proper Origin header; `Access-Control-Allow-Origin: *` from Supabase is honoured; canvas isn't tainted; `toBlob` works. No data URL swap needed at all. **This is the simplest fix.** The cost: existing tabs need to hard-refresh to bust the CORS-less cached entries.

2. **Replace html2canvas with `dom-to-image-more` or `modern-screenshot`.** These libraries handle the CORS pre-fetch internally and have better-documented async behavior. Adds a dependency but removes the fight with html2canvas's clone-phase resource loader.

3. **Render server-side.** Vercel function takes the planId, fetches `get_plan_full`, server-renders the lobby HTML to PNG via Puppeteer or Playwright, returns the PNG. Removes the entire client-side CORS surface. More infrastructure but more reliable. Beware Vercel function execution time limits.

4. **Manual SVG/Canvas rendering.** Skip html2canvas entirely. Iterate the lobby data and draw each row to a canvas with `ctx.drawImage`, `ctx.fillText` etc. Most work but full control over output. The lobby visual structure is simple enough (header strip, list of rows, footer) that this is feasible.

## Things to NOT redo

- Don't try `<a href={blobUrl} download>` after `await` — user-activation is lost.
- Don't try `window.open('about:blank')` synchronously then update — popup blockers fire.
- Don't use `visibility: hidden` on a clone container — html2canvas respects it.
- Don't swap srcs in `html2canvas`'s `onclone` callback expecting them to load — the resource loader already ran.
- Don't gate `_uploadRawArchives` or any new variant upload behind `rawArchiveUploadedAt` — see `gotcha_upload_fastpath_skips_new_variants.md`.

## Scope creep that landed correctly along the way

Two real bugs Carl identified got fixed properly during this slog. These are NOT regressions — keep them:

- **PR #266 — `get_plan_full` existence-checks thumbnail variants in `storage.objects`.** Older plans (pre-PR #263) don't have `_thumb_line.jpg` / `_thumb_color.jpg` in storage; the RPC now returns NULL → web player falls back to legacy B&W instead of broken-image glyph.
- **PR #267 — `get_plan_full` body restored.** PR #263 + #266 dropped the `sets` array (and segmented URLs, mask URL, photo treatment branches) when I copy-pasted a fresh body without sourcing `pg_get_functiondef` first. Schema-migration column-preservation gotcha. Memory entry: `feedback_schema_migration_column_preservation.md`.
- **PR #268 — variant-thumb backfill in `upload_service.dart`.** Both fast-paths (media bucket and `_uploadRawArchives`) skipped uploads when every exercise had `rawArchiveUploadedAt != null`. New variants (added after the original fast-path was written) never landed for previously-published plans. Now the existence-check + upload-if-missing pass runs unconditionally. Memory entry: `gotcha_upload_fastpath_skips_new_variants.md`.

## Files touched

- `web-player/lobby.js` — share button click handler + `triggerLobbyShare` + modal helpers
- `web-player/index.html` — share button DOM + (since-removed) modal markup
- `web-player/styles.css` — share button + modal styles
- `web-player/app.js` — `PLAYER_VERSION` bumps
- `web-player/sw.js` — `CACHE_NAME` bumps
- `web-player/html2canvas.min.js` — vendored html2canvas@1.4.1
- `app/ios/Runner/UnifiedPlayerSchemeHandler.swift` — serves vendored html2canvas to Workflow Preview
- `app/lib/services/upload_service.dart` — variant-thumb backfill
- `supabase/schema_get_plan_full_restore_full_body.sql` — restored full RPC body
- `supabase/schema_lobby_three_treatment_thumbs_existence_check.sql` — existence-check thumb URLs

## How to reproduce

1. Open `https://session.homefit.studio/p/087486bb-20d3-4b6b-b52f-ab0bf050ee84` on macOS Safari or Chrome
2. Hard-refresh once (Cmd+Shift+R) to ensure latest SW
3. Wait for lobby to load
4. Tap the share button (icon left of the gear)

If v69 works, you'll see a modal with the rendered PNG. If it doesn't, you'll either see the spinner stuck, an error message, or nothing at all (regression to round 10).
