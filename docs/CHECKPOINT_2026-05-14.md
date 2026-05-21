# Checkpoint — 2026-05-14 — Hero treatment principle + no-fallback + lobby PDF + scheme handler hardening

**The big day for visual consistency.** Carl ratified two load-bearing product principles that reshape how the app renders heroes everywhere, and we landed a stack of PRs to honor them. Plus a pivot of the lobby's "share as static artifact" from PNG to multi-page PDF, plus fixes for an iOS embedded-preview bug that took two hotfixes to fully resolve. End state: 18 PRs merged to staging, install on iPhone CHM at staging tip `3ce7579`, ready for QA.

## Table of Contents

- [Status](#status)
- [The two principles ratified today](#the-two-principles-ratified-today)
- [What landed today](#what-landed-today)
- [The iOS embedded-preview bug story](#the-ios-embedded-preview-bug-story)
- [Outstanding QA on the current install](#outstanding-qa-on-the-current-install)
- [Stacked for the next session](#stacked-for-the-next-session)
- [Memory rules added today](#memory-rules-added-today)
- [Fresh-session handoff guide](#fresh-session-handoff-guide)

## Status

- **Staging tip:** `3ce7579` (Merge of PR #333 — scheme handler auto-register).
- **iPhone CHM install:** staging tip `3ce7579` via `./install-device.sh staging`, ready for Carl's QA round.
- **Main tip:** `3928885` (untouched today — only the photo/video treatment audit doc went direct-to-main this morning; all code went through staging).
- **Vercel staging surfaces:** `staging.session.homefit.studio` and `staging.manage.homefit.studio` auto-deploy on every staging merge; both at parity with staging code.
- **Supabase:** staging branch `vadjvkmldtoeyspyoqbx` has all migrations applied (no new migrations today beyond what Bundle 2b shipped yesterday).
- **Blocked on Carl (unchanged):** Hostinger 301 redirects · `support@homefit.studio` mailbox · ZA lawyer red-pen · PayFast production merchant.

## The two principles ratified today

### Principle 1 — Hero pictures always reflect the practitioner's per-exercise choice

Wherever an exercise's hero picture appears in the product — Studio card, lobby row, prep countdown, deck poster, filmstrip cell, capture peek, snapshot PNG, embedded preview — the resolver picks the variant matching that exercise's `preferred_treatment` field as the practitioner set it. No surface gets to override that (no more "the filmstrip is always B&W" rule, no more "the prep overlay always shows the cached thumbnail regardless of treatment").

This is a stronger, cleaner rule than what the codebase shipped with. The previous design had localized aesthetic overrides scattered across multiple surfaces; the new rule consolidates the source of truth to the exercise model itself.

### Principle 2 — No silent fallbacks across treatments or media kinds

If the practitioner's chosen treatment variant isn't available (file missing on disk, signed URL expired, consent revoked on the cloud surface), the surface renders an explicit "treatment not available" placeholder (coral skeleton with the exercise name) — NOT a silently substituted different treatment's image.

The old fallback chains (`grayscale URL → fall back to thumbnail URL`, `archive video → fall back to converted line`, etc.) were masking real bugs. With the no-fallback principle, failures become observable; the practitioner sees the gap and can act.

**The combined effect of the two principles:** every hero picture across the product now tells a true story. If the practitioner sees a B&W image on a Studio card, that's because the exercise's treatment is B&W. If they see a coral placeholder, it's because the file genuinely isn't there. No more "looks right but is actually wrong" failures.

## What landed today

18 PRs merged to staging. Grouped by theme:

### Photo vs video treatment audit + refactor (5 PRs)

The audit doc `docs/audits/photo-video-treatment-audit-2026-05-13.md` (committed direct-to-main yesterday-into-today) mapped how 8 different rendering surfaces independently re-derived "which file + which treatment" without a shared contract. The audit found four QA failures (lobby leak, snapshot color mismatch, single-cell photo filmstrip, photo pipeline gaps) all rooted in the same divergence.

- **#316** Bundle 1 — first-pass: drop "Soon" pill from AppBar, coming-soon teasers on body pages, lobby import card stub.
- **#318** Bundle 1 web resolver — `web-player/exercise_hero.js`; lobby uses it per-row; prep + deck posters treatment-correct.
- **#320** Bundle 2a Flutter resolver + filmstrip rule — `app/lib/services/exercise_hero_resolver.dart`; F17 "show photos when no videos" fix.
- **#319** Bundle 2b photo variant pipeline — `_thumb.jpg` / `_thumb_color.jpg` / `_thumb_line.jpg` extracted for photos at capture time; symmetric to video. Supabase migration widens `get_plan_full` to surface variant URLs for photos too.
- **#324** Refactor — resolver API drops `treatment` + `bodyFocus` params; resolver derives them from `exercise.preferred_treatment` + `exercise.body_focus` internally. No silent fallbacks; missing variants render the coral `.hero-not-available` placeholder.

### Lobby export pivot to multi-page PDF (3 PRs)

The freemium "share the lobby as a static artifact" feature got a complete redesign. PNG is retired; output is now multi-page PDF.

- **#321** Modal exclusion (D10) — html2canvas `ignoreElements` so the share modal doesn't get baked into the exported image.
- **#325** Pivot to multi-page PDF — jsPDF + html2canvas. 5 exercises per page, circuits don't split across pages, page-1 thumbnail preview with "1 of N pages" badge, native iOS Save-to-Files bridge.
- **#328** Tainted-canvas hotfix — pre-fetch cross-origin signed-URL images via fetch+blob so html2canvas can rasterise them without hanging.

### Lobby fixes from QA (4 PRs)

- **#322** E14 circuit animation in iOS WebView — fourth attempt; root cause was a CSS animation with an undefined variable shadowing the JS-driven animation.
- **#326** Studio card layout — square hero on the left, text column on the right (matches lobby pattern). Plus a small video/photo icon overlay.
- **#329** Unified gear popover — lobby gear and per-exercise gear show the same content; all settings are session-scoped; "Reset to practitioner" button.
- **#331** Visual polish — move the media-type badge from the hero image area to the top-left of the text column; state chips + media-type icon 50% larger.

### Studio session card filmstrip (1 PR)

- **#332** Filmstrip rule — videos first up to 4, then photos to fill remaining slots (was: "videos win, drop photos" which gave you single-cell strips for mixed sessions).

### Conversion pipeline hardening (1 PR)

- **#323** Granular per-variant failure handling — if one of the three thumbnail variants fails to extract, the others still ship and the failure is logged to the long-press "N failed" pill. Plus eager backfill on session-open for legacy exercises missing variants.

### iOS embedded-preview scheme handler fixes (3 PRs)

This was where most of the day's debugging time went. See the dedicated story section below.

- **#327** First hotfix — drop client-consent gate on local URLs in the bridge (consent is a cloud-surface concern; practitioner preview shouldn't be gated by it).
- **#330** Second hotfix — add the two new asset files (`exercise_hero.js`, `jspdf.umd.min.js`) to the iOS scheme handler's hardcoded route list.
- **#333** Long-term fix — make the scheme handler data-driven so any file in the bundle is automatically routable. Future new files don't need a Swift change.

## The iOS embedded-preview bug story

A story worth telling in plain English because it touched several concepts:

The iPhone app shows an in-app preview of the workout lobby via an embedded browser window. That browser asks for the web player's HTML/JS/CSS files. Inside the iOS app there's a small "switchboard" that intercepts those requests and says "this file lives inside the app bundle, serve it from there." The switchboard had a hardcoded list of file names it recognized.

Earlier today we added two new files to the bundle:
- A new "hero-rendering brain" for the lobby (the resolver from PR #324)
- The PDF library for the new export (from PR #325)

Both files got copied into the bundle correctly. But the switchboard's hardcoded list wasn't updated, so when the embedded browser asked for them, the switchboard didn't recognize the request and the response just never arrived. The browser waited forever, no error.

Cascading effects: the hero resolver never loaded, so the lobby's defensive fallback rendered gray placeholders for every exercise. The PDF library never loaded, so the share button surfaced a "PDF library failed to load" error. The gear popover misbehaved because it depended on the resolver too.

The fix was three layers:
1. PR #327 — drop a separate but related issue (the bridge was gating treatment URLs by client consent on the practitioner's own preview, which is the wrong scope).
2. PR #330 — add the two new files to the hardcoded list (immediate hotfix).
3. PR #333 — make the switchboard data-driven so it auto-discovers any file in the bundle (long-term prevention).

Why CI didn't catch it: CI verifies that the bundled files match the source files (a "drift-guard"), but it doesn't verify that every bundled file has a corresponding entry in the iOS switchboard. That gap was only visible on the device.

## Outstanding QA on the current install

iPhone CHM is at staging tip `3ce7579`. Open the `studio.homefit.app.dev` icon. Test scripts under `docs/test-scripts/` cover the recent waves. The most impactful items:

### Hero treatment principle in action

1. Studio card heroes reflect each exercise's `preferred_treatment` (capture two exercises with different treatments → cards visually differ)
2. Filmstrip on session cards shows mixed treatments correctly (was uniformly B&W before today)
3. Embedded preview lobby now shows real hero images (this morning it was gray placeholders for everyone — the fixes #327, #330, #333 stack)
4. Lobby per-row treatment doesn't leak (first exercise set to Line no longer drags everyone else to Line)
5. Prep countdown hero matches the upcoming exercise's treatment

### Lobby PDF export

6. Tap Share on the lobby (live web at `staging.session.homefit.studio` OR embedded preview) → multi-page PDF generates
7. Modal shows "1 of N pages" badge with first-page thumbnail preview
8. On iPhone: Download PDF saves to Files via the native bridge; Share opens the iOS share sheet
9. PDF should NOT contain the share modal overlay (#321) or active-exercise coral highlight (#10.1 polish)
10. Long plans (8+ exercises) → all pages render, no cut-offs

### Studio card layout + media-type indicators

11. Studio exercise card has square hero on the left, text on the right
12. Video / photo icon (50% larger now) sits in the top-left corner of the text column
13. State chips (treatment / body-focus / audio when set) also 50% larger, in the chip strip below notes

### Settings consistency

14. Lobby gear popover and per-exercise (deck) gear popover have identical content
15. Tapping Line/B&W/Colour in either popover applies session-wide (not just to current exercise)
16. "Reset to practitioner" returns to mixed-treatment per practitioner's per-exercise settings

### Conversion hardening

17. Long-press the "N failed" pill on a session card (if any failures) → bottom sheet shows per-variant log entries
18. Re-open a legacy session (pre-Bundle-2b) → backfill regenerates missing thumbnail variants in the background

### Smoke

19. Capture a fresh video → all three thumbnail variants written to disk (`_thumb.jpg`, `_thumb_color.jpg`, `_thumb_line.jpg`)
20. Capture a fresh photo → same three variants written
21. Publish → live web player renders heroes correctly with the practitioner's chosen treatments

## Stacked for the next session

These items came up during today's QA but weren't urgent enough to ship today:

- **Cosmetic version chip** — the `PLAYER_VERSION` constant in the web player's footer reads `v69-modal-first-desktop` (a stale const that nobody updates on releases). CLAUDE.md claims `HOMEFIT_CONFIG.gitSha` is wired into the chip, but the actual code never reads from it. Should bump or replace with a real deploy SHA. Low priority — cosmetic.
- **Backlog: practice-level configurable default treatment** — currently the "default" treatment for a new capture is hardcoded to whatever the sticky preference is (Wave 309 default = B&W). Eventually owner should be able to set a per-practice default. No practice settings surface exists yet. Backlog item.
- **Backlog: PDF artifact polish** — Carl wants to review the actual exported PDF visually and request artifact-level tweaks (font sizes, padding, what's included, etc.). Deferred until export is reliably working — which it now is, so this can happen on the next QA pass.
- **Test-scripts/index.html structural drift** — multiple successive PRs have added entries at position #1 without properly closing prior `<li>` blocks. The file still renders but has overlapping nesting. Should be rebuilt cleanly in a maintenance pass. Not user-facing.
- **Filmstrip aesthetic** — the new rule shows photos and videos side-by-side. Treatment-rendering is per-cell; B&W videos and color/line photos can sit next to each other. Carl will probably want a visual tweak pass once he's seen real mixed sessions in the filmstrip.

## Memory rules added today

Two new memory entries in `~/.claude/projects/-Users-chm-dev-TrainMe/memory/`:

- **`feedback_explanation_level.md`** — Pitch explanations at plain-English level. Carl isn't technical; default to high-level story-style explanations for bug post-mortems, status updates, architecture decisions. Skip file paths and code refs in narrative prose unless he asks for more detail. Sub-agent briefs + commit messages + code comments stay technical.

The hero treatment principle and no-fallback principle themselves aren't in memory yet — they live in the audit doc and the codebase. Worth adding as a feedback memory next session if it comes up.

## Fresh-session handoff guide

For a fresh Claude session picking up this work:

1. **Read this checkpoint** — it captures the day's intent and outcomes.
2. **Read `docs/audits/photo-video-treatment-audit-2026-05-13.md`** — the load-bearing architectural document that drove the refactor.
3. **Read `CLAUDE.md`** — project rules.
4. **Read the latest memory files** under `~/.claude/projects/-Users-chm-dev-TrainMe/memory/MEMORY.md` — invariants Carl has set over time.
5. **Carl's iPhone is on staging at `3ce7579`** — open the `studio.homefit.app.dev` icon. He's mid-QA.

If Carl asks "what happened to the embedded preview lobby today" — point him at the iOS embedded-preview bug story section above. The fix landed in three layers.

If Carl asks "why is hero treatment behaving differently now" — point him at the two principles section. The whole product now consistently reflects practitioner choice; the previous "surface-X is always Y" rules are retired.

Open question state when handing off: none. Carl is testing the install. Next agent should:
- Wait for Carl's QA results
- Fix anything that surfaces (probably small)
- If QA passes → discuss staging → main promotion + TestFlight v2

The release-train infrastructure (per `docs/CHECKPOINT_2026-05-11.md`) is fully in place; promoting staging → main is the standard "Merge with merge commit" flow. The auto-tag workflow will stamp `v2026-05-14.N` on the merge.
