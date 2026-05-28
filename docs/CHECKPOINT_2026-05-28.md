# Checkpoint — 2026-05-28 — artifact-card accordion + the handout three-fix saga + publish-flow fixes

A long device-QA-driven session. Carl tested the artifact-stacking UI that shipped the prior night, decided the Studio fanned-deck "polluted" the editing surface, and we redesigned it into a per-session **accordion** that lives on the client/My-Workouts session lists instead — then iterated it three times on live device feedback (button positions, empty-state slider, mirrored collapse animation). In parallel, the workout **handout** page was stuck on "Loading your plan" — it survived three wrong fixes (config.js order, a watchdog, URL cache-busting) before a simulator reproduction with on-screen diagnostics proved the real cause was a one-line **CSS bug** (`[hidden]` defeated by an author `display:flex` rule) — the page had been rendering all along under a permanent loading overlay. We also fixed the **publish flow**: the Publish button no longer dead-ends (always-enabled + no-op toast), the publish gate pre-checks the workout so edits can actually re-publish, and all already-published artifacts become opt-in "Out of date" re-publish rows (free). Finally, the per-exercise + session-level "unpublished changes" **spine** was spec'd + mocked for a fresh session (not built — it needs a schema migration).

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [PR sequence](#pr-sequence)
- [Specs + mockups committed to main](#specs--mockups-committed-to-main)
- [Memory rules added today](#memory-rules-added-today)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- Where main is: `ed9f3a4` (docs/specs only — the change-spine spec)
- Where staging is: `6cec276` — [PR #560](https://github.com/carlheinmostert/TrainMe/pull/560)
- Where Carl's iPhone is: `6cec276` (staging) — the full artifact-accordion + handout-fix + publish-flow stack
- Blocked on Carl (unchanged): Hostinger 301 redirects (`homefit.studio/privacy|terms`), `support@homefit.studio` mailbox, ZA lawyer red-pen of privacy/terms, PayFast production merchant account. Plus the two artifact-system items still outstanding from the 2026-05-26 checkpoint: Supabase Auth redirect allowlist for the `/me` claim flow, and `RESEND_API_KEY` + `supabase functions deploy send-artifact-email`.
- **All 12 PRs this session are on `staging` only** — not yet promoted to `main`/prod. A staging → main promotion is the natural next milestone once device QA fully closes.

## The day's big decisions

1. **Artifact stacking moved OFF Studio.** The fanned-deck above the Studio exercise list (shipped the prior night as PR #548) was judged to pollute the editing surface. It was replaced by a per-session **accordion** on the browsing surfaces — the client-detail session list, My Workouts, and the web `/me` page. Studio is purely an editing surface again. The session card gains a subtle "peek" depth hint; tapping a chevron fans the artifact cards out beneath it.

2. **The accordion was iterated three times on live device feedback** — not designed once. First pass (single chevron), then: two stacked action buttons (Studio + Artifacts) with chosen icons, a coral rail moved into a visible gutter, a slowed "deal of cards" expand animation, then button repositioning (Studio centered, Artifacts bottom), an always-visible artifacts button with an empty-state slider for unpublished sessions, and a collapse animation that mirrors the expand. Each round went through a mockup Carl signed off before code.

3. **The handout bug was a CSS overlay, not anything we first thought.** It survived three fixes aimed at the JavaScript/data/cache path. The real cause: the loading spinner's `display:flex` (author CSS) always beats the user-agent `[hidden]{display:none}` rule, so the JS that set `hidden=true` did nothing and the finished page stayed buried. The decisive move was reproducing in the simulator with on-screen diagnostics — proving the data loaded and `render()` completed while the overlay never lifted. Fix was one line.

4. **Publish flow made forgiving + correct.** The Publish button no longer disables to a dead-looking state — it's always tappable, with a "Nothing to publish — already up to date" toast on the no-op path (no credit charge). The publish gate now pre-checks the workout so you can actually re-publish edits to an already-published plan (previously impossible — the workout row was locked "Live"). And every already-published artifact (handout included) becomes an opt-in "Out of date" re-publish row when the session has edits — default unchecked, always free to re-publish (re-publishing an already-paid artifact never re-charges).

5. **The "unpublished changes" indicator is a spec, not a build (yet).** Carl wants a coral left-edge "spine" on any card with unpublished edits, applied consistently at both the exercise-card and session-card levels. The session level can use the existing dirty signal, but the exercise level needs a new per-exercise timestamp column plus stamping every content-edit site — too much to land safely at the tail of a long session, so it was spec'd + mocked for a fresh session.

## PR sequence

All merged to `staging`. Several were salvaged from sub-agents that stalled on cold OpenCV-from-source builds before committing — see Lessons.

| # | Title | Why |
| --- | --- | --- |
| [#549](https://github.com/carlheinmostert/TrainMe/pull/549) | artifact-card accordion (replaces #548 fanned-deck) | Move stacking off Studio onto session lists + `/me` |
| [#550](https://github.com/carlheinmostert/TrainMe/pull/550) | handout stuck on "Loading your plan" (config.js order) | Wrong fix #1 — necessary but insufficient |
| [#551](https://github.com/carlheinmostert/TrainMe/pull/551) | accordion iteration (rail gutter + stacked buttons + slower anim) | First device-feedback round |
| [#552](https://github.com/carlheinmostert/TrainMe/pull/552) | accordion evening iteration (button positions + empty-state + collapse mirror) | Second device-feedback round |
| [#553](https://github.com/carlheinmostert/TrainMe/pull/553) | handout defensive watchdog (round 2) | Wrong fix #2 — a fail-loud safety net, not root cause |
| [#554](https://github.com/carlheinmostert/TrainMe/pull/554) | handout URL cache-busting `?v={sha}` | Wrong fix #3 — chased a stale cache that wasn't the cause |
| [#556](https://github.com/carlheinmostert/TrainMe/pull/556) | Studio Preview artifact picker + remove "1cr" subtitle | Preview kind-picker + a cache-proof local handout test path |
| [#557](https://github.com/carlheinmostert/TrainMe/pull/557) | Publish always-enabled + no-op toast | Dead-looking disabled button fixed |
| [#558](https://github.com/carlheinmostert/TrainMe/pull/558) | handout un-hide — `[hidden]` defeated by `display:flex` | **The true root cause.** One CSS line |
| [#559](https://github.com/carlheinmostert/TrainMe/pull/559) | pre-check workout-plan in publish gate (edits re-publish, free) | Couldn't re-publish edits to a published plan before |
| [#560](https://github.com/carlheinmostert/TrainMe/pull/560) | all stale artifacts re-publishable (opt-in, free) on edit | Handout no longer silently stale + locked |

(PR #548 — the original Studio fanned-deck — landed at the very start and was superseded by #549.)

## Specs + mockups committed to main

Direct to `main` per specs-direct-to-main:

- `docs/specs/2026-05-27-artifact-card-expansion.md` — the accordion spec, with three iteration-log sections capturing each device-feedback round.
- `docs/design/mockups/2026-05-27-artifact-card-expansion.html` — the interactive accordion mockup (final state).
- `docs/specs/2026-05-28-exercise-change-marker.md` — the unpublished-changes spine spec (session + exercise levels, schema, edit-site enumeration, ACs).
- `docs/design/mockups/2026-05-28-exercise-change-marker.html` — the spine mockup (Option A locked, shown at both levels).

## Memory rules added today

- [gotcha_hidden_attr_defeated_by_display.md](../../.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_hidden_attr_defeated_by_display.md) — an author `display:` rule always beats the UA `[hidden]{display:none}` rule (author origin > UA origin, regardless of specificity). JS setting `el.hidden = true` is a no-op against it. Add `[hidden]{display:none !important}` or stop setting `display` on hideable elements. Cost: three wrong handout fixes before the runtime repro found it.

## Open follow-ups for next session

- **Device QA: item 5 redux on `6cec276`.** Carl was about to re-test the publish gate showing the handout as an opt-in "Out of date" row (not force-selected). Confirmation pending. Items 1–4 already passed (handout renders via both Studio Preview and the published artifact card — the CSS fix is verified on device).
- **Work B — the unpublished-changes spine** (chip ready to click). Spec: `docs/specs/2026-05-28-exercise-change-marker.md`. Needs SQLite `_dbVersion` 48→49 (`last_edited_at` column) + stamping every content-edit site, plus the session-level spine off the existing signal. One open decision for Carl: does **reorder** light the spine? (Proposed: no.)
- **Bundle-drift cleanup** (chip ready). `app/assets/web-player/` drifted from `web-player/` source for 7 files + a stray `sw.js`; the CI drift guard only checks 4 files. Re-sync + switch the guard to a run-the-sync-and-assert-no-diff full compare (self-maintaining).
- **Staging → main promotion.** 12 PRs are staging-only. Once device QA closes, promote.

## Lessons / gotchas

- **After two failed static-analysis guesses, get runtime evidence.** The handout bug was diagnosed wrong twice from reading code (cache theory, then planId-mismatch theory). The win came from a simulator reproduction that rendered the JS decision trail into the DOM and read it back via the simulator's screenshot/accessibility tooling — no Safari Web Inspector GUI needed. Captured values (isLocalSurface true, planId extracted, render() returned, yet "Loading" still showing) pinpointed a CSS overlay in one shot.
- **Cold-worktree OpenCV-from-source builds stall agents (~10 min) and kill them mid-task.** THREE agents this session (publish-button, gate-precheck, gate-stale-artifacts) stalled on the build verification step and died before committing/opening a PR. Each was salvaged: verify the worktree diff, commit manually, push, open the PR, let CI do the build the agent couldn't. The pattern is now routine but expensive — consider warming a shared worktree or skipping the agent-side full build when CI will build anyway.
- **`devicectl install` over an existing app is an UPGRADE, not a clean install** — it does not clear the app's WKWebView data store. This wasted time on the handout cache theory (force-quit + reinstall never cleared the suspected cache because the cache wasn't the problem AND upgrade-install wouldn't have cleared it anyway).
- **A locked "Live" row read as "selected/mandatory" to Carl.** Visual language matters: an already-published artifact shown with a sage "Live" badge looked like it was force-selected for publishing. The fix surfaced it as an explicit opt-in "Out of date" state instead.

## Fresh-session handoff

**READ THIS FIRST.** This checkpoint supersedes `docs/CHECKPOINT_2026-05-26.md` and `docs/CHECKPOINT_2026-05-26-artifact-system-waves-4-5.md` as the latest state. Staging tip is `6cec276`; Carl's iPhone is on it. The session was a device-QA marathon: the artifact-stacking UI was redesigned into a session-list accordion (3 iteration rounds), the handout "Loading your plan" bug was finally root-caused to a CSS overlay (`[hidden]` vs `display:flex`, fixed in #558 after three wrong fixes), and the publish flow was made forgiving + correct (always-enabled button, gate pre-check, opt-in "Out of date" re-publish). Two things are spec'd-and-chipped but NOT built: the unpublished-changes **spine** (`docs/specs/2026-05-28-exercise-change-marker.md`) and the **bundle-drift** cleanup — both have one-click chips. Immediate open item: confirm item-5-redux device QA (the opt-in "Out of date" gate) passed on `6cec276`. All 12 PRs are staging-only — a staging → main promotion is the next milestone once QA closes.
