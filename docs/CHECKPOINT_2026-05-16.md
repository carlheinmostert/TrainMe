# Checkpoint — 2026-05-16 — Circuit attempt #10 ships, hero resolver lands, 9 skills installed

**The day the circuit-animation saga ended (attempt #10, variant 1 outward ripple, pure CSS — landed and verified on iPhone), the publish flow grew a fallback diagnostic surface plus atomic media-bucket uploads, a centralised hero-crop resolver killed the PDF object-fit bug as a side effect, three layers of enforcement got wired so the resolver can't re-fragment, and nine `homefit-*` skills landed for recurring workflows.** 5 PRs merged, 2 direct-to-main docs, 3 new memory entries, 9 skills. Carl's iPhone ends the day on staging tip `5e107f8` (PR #362 squash-merge).

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [PR sequence](#pr-sequence)
- [Direct-to-main commits](#direct-to-main-commits)
- [Skills installed today](#skills-installed-today)
- [Memory rules added today](#memory-rules-added-today)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Main tip:** `59115ef` — `docs: HERO_RESOLVER.md — single-source-of-truth rule for hero image rendering`.
- **Staging tip:** `5e107f8` — `fix(publish): diagnostic surface for non-atomic upload failures + atomic media-bucket uploads (#362)`. Staging contains PRs #362, #363, #364, #365 plus the test-scripts/index.html conflict resolve commit `b5b0a14`.
- **iPhone CHM:** build SHA `5e107f8` installed at 11:00 UTC via `./install-device.sh staging`. Bundle `studio.homefit.app.dev`, ENV=staging. The mid-day build at `52ba60d` (PR #362's pre-squash tip) was also installed earlier for the tap-dead verification; the latest install supersedes it.
- **Vercel staging surfaces:** `staging.session.homefit.studio` auto-deployed PR #364 (hero crop resolver) — the PDF object-fit bug should now be gone live. `staging.manage.homefit.studio` unchanged today.
- **Blocked on Carl (unchanged):** Hostinger 301 redirects · `support@homefit.studio` mailbox · ZA lawyer red-pen of privacy/terms · PayFast production merchant account.

## The day's big decisions

Three load-bearing decisions, all reflected in code or docs on main / staging.

1. **The hero crop is shared logic; it lives in ONE resolver, never inline.** Five surfaces (Flutter Studio card, filmstrip, camera peek, web lobby live, web lobby PDF) used to each do the crop math themselves. The PDF squashed portraits to 1:1 because html2canvas ignores `object-fit: cover` — the symptom that proved the duplication problem. PR #364 centralised the web side into `web-player/hero_resolver.js`. The Flutter migration is in BACKLOG. Three enforcement layers landed: `docs/HERO_RESOLVER.md` (spec), a memory entry, and a CI grep rule that fails the build if anyone reintroduces inline crop math.

2. **Long-press on a Studio card means reorder, not replace-media.** Carl spotted the regression — hidden gestures had captured what should be a labelled control. The fix shape is final but not yet shipped: drop the `onLongPress: onReplaceMedia` from the card InkWell + add a "Replace" pill on the Demo surface above the existing Rotate pill, same coral-bordered visual pattern. Agent was killed mid-implementation — the working tree on the feature branch carries the partial changes uncommitted.

3. **Skills are a first-class tool for recurring workflows.** Nine `homefit-*` skills landed in user-invocable form: ship-to-phone, write-checkpoint, where-are-we, cleanup-worktrees, resolve-test-script-index, promote-staging-to-main, add-memory, agent-brief, vercel-spend. They encode the memory rules so the workflows happen the same way every time — for both Claude and human contributors.

## PR sequence

In merge order:

| # | PR | Title | Why |
|---|---|---|---|
| 1 | [#361](https://github.com/carlheinmostert/TrainMe/pull/361) | `fix(player): circuit animation attempt 10 — nested CSS boxes` | The 10th-and-final attempt at the recurring circuit-animation bug. Variant 1 outward ripple, pure CSS keyframes on N nested div rings, no SVG, no JS, no observers. Merged 2026-05-15 16:12 UTC (carry-over from previous session, included for completeness). |
| 2 | [#363](https://github.com/carlheinmostert/TrainMe/pull/363) | `chore(schema): add practice_id column to local sessions table (DB v39)` | SQLite mirror schema bump so sessions can be queried by practice context. Direct-to-main (no staging hop). |
| 3 | [#364](https://github.com/carlheinmostert/TrainMe/pull/364) | `refactor(player): centralise hero-crop resolution + fix PDF object-fit bug` | New `web-player/hero_resolver.js` module. Lobby + PDF both consume cropped data URLs. CSS `object-fit: cover` dropped on `.lobby-hero-media`. PDF portrait-squash bug fixed as a side effect. BACKLOG entry filed for the Flutter consumer migration. |
| 4 | [#365](https://github.com/carlheinmostert/TrainMe/pull/365) | `chore(ci): enforce hero-resolver single-source-of-truth rule` | New `scripts/ci/check-hero-resolver.sh` wired into the existing custom-rules job. Three forbidden patterns: stray `object-fit: cover` on `.lobby-hero-media` (video variant exempted), `heroCropOffset` reads outside the 10-file allow-list, static `<img>` with `_thumb*.jpg` srcs in lobby code that bypass hydration. Build-time fail with clear file:line + resolver alternative. |
| 5 | [#362](https://github.com/carlheinmostert/TrainMe/pull/362) | `fix(publish): diagnostic surface for non-atomic upload failures + atomic media-bucket uploads` | Two fixes in one. Fix A: fallback "Show error details →" tap-target for non-file failures (network, RLS, RPC) opens a new `UploadErrorDetailsSheet`. Fix B: media-bucket uploads now atomic with per-file failure records — "Show which files →" fires for them too. Tap-dead bug from Carl's QA round (modal pushed onto unreachable navigator scope) fixed by dropping `useRootNavigator: true` on both diagnostic sheets. Sensitive zone (publish flow); merged after Carl's explicit go-ahead. |

## Direct-to-main commits

| SHA | Subject | Why |
|---|---|---|
| `2386e5d` | `docs(design): amplify circuit nested-boxes mockup animations` | The 6-variant circuit mockup's keyframes were too subtle to perceive (3px shadow at 45% opacity coral over 2px full-opacity coral border). Carl reported "no movement across any of the six versions." Amplified to 25% baseline border + 100% peak with 24px outer glow. Plus a `prefers-reduced-motion` override that keeps the static rings visible. |
| `59115ef` | `docs: HERO_RESOLVER.md — single-source-of-truth rule for hero image rendering` | Layer 1 of the hero-resolver enforcement. Codifies the rule, the why (5-surface duplication + PDF symptom), the resolver API (web today + Flutter future), the forbidden-patterns table with correct alternatives, the allow-list. TOC at top. |

## Skills installed today

Nine `homefit-*` workflow skills, all user-invocable via the Skill tool. Discovery came from a research agent scanning recent session transcripts for recurring multi-step rituals.

| Skill | What it does |
|---|---|
| `homefit-ship-to-phone` | Build + install staging Flutter app to iPhone CHM, author a device-QA test script, emit a numbered test list. Encodes 4 memory rules. |
| `homefit-write-checkpoint` | Author the daily `docs/CHECKPOINT_<date>.md`, commit direct-to-main via ephemeral worktree, pull back into Carl's worktree. This skill authored this checkpoint. |
| `homefit-where-are-we` | Fresh-session context briefing. Reads latest checkpoint, lists open PRs, shows iPhone build SHA, surfaces what's blocked on Carl. |
| `homefit-cleanup-worktrees` | Prune merged, stale, or orphaned agent worktrees under `.claude/worktrees/agent-*`. ~120 alive at the time of scanning. |
| `homefit-resolve-test-script-index` | Auto-fix merge-conflict cascades in `docs/test-scripts/index.html` — the multi-region kind that has shipped to main twice. |
| `homefit-promote-staging-to-main` | Draft the release-promotion PR from staging to main. Stops before merge; Carl explicitly promotes. |
| `homefit-add-memory` | Capture a session learning as a typed memory file + append to MEMORY.md index. |
| `homefit-agent-brief` | Compose a clean sub-agent brief with the standard conventions baked in (repo-relative paths, R-10 parity, no direct DB, target staging, branch naming, no emojis). |
| `homefit-vercel-spend` | Pull MTD Vercel spend for the homefit projects, compare against last snapshot, flag spikes. |

## Memory rules added today

- [iOS Reduce Motion kills CSS animations in WKWebView](../../../../Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_ios_reduce_motion_kills_animation.md) — When animation works on desktop but not iPhone, FIRST check iOS Settings → Accessibility → Motion → Reduce Motion before any CSS / DOM debugging. Saved 9 attempts of pain on the 10th-attempt circuit fix.
- [Stale per-treatment thumbnail — scrub Hero offset to regenerate](../../../../Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_stale_thumbnail_scrub_hero_to_regen.md) — When ONE specific video exercise's B&W Hero looks blurred but Colour is sharp, suspect a stale `_thumb.jpg` from an earlier converter pass. Fix is to scrub the Hero offset by one frame; the 250ms debounce triggers `regenerateHeroThumbnails`. Confirmed today.
- [Hero resolver is the single source of truth for hero-image rendering](../../../../Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/feedback_hero_resolver_single_source.md) — All hero rendering on every surface goes through the resolver. No inline crop math anywhere. Linked spec at `docs/HERO_RESOLVER.md`. CI grep rule enforces.

## Open follow-ups for next session

1. **Replace pill PR (P0 — regression unfixed).** The agent that was building the fix for `fix/studio-replace-pill-restore-reorder` was killed mid-edit while modifying `_buildBottomLeftChromeCluster`. The working tree on that branch (the origin repo's current branch — Carl's worktree was deleted, the origin repo is now checked out here) carries two modified files uncommitted: `app/lib/widgets/studio_exercise_card.dart` and `app/lib/screens/studio_mode_screen.dart`. Decide whether to resume the work-in-progress or restart fresh in next session.

2. **iPhone QA — sweep the 5 merged PRs.** Carl has staging tip `5e107f8` installed but didn't get to walk a full test pass before the session ended. Run the test scripts at top of `docs/test-scripts/index.html`: publish diagnostic surface (PR #362) + hero crop resolver (PR #364) + circuit attempt #10 (PR #361, may already be verified). PDF export on a portrait video should now show a properly-cropped 1:1 hero instead of a squashed portrait.

3. **Flutter hero-resolver migration.** Logged in `docs/BACKLOG.md` by PR #364's agent. The 5 Flutter consumers (Studio card, filmstrip cell, camera peek, editor sheet, plan preview) currently do their own `Alignment` math against `exercise.heroCropOffset`. Migration extends `app/lib/services/exercise_hero_resolver.dart` to carry crop semantics + adds a `CroppedHero` builder that consumers invoke instead of computing alignment themselves. The CI grep rule (PR #365) already covers the Flutter file list with an allow-list, so the rule will catch new offenders before merge.

4. **Worktree cleanup.** ~120 agent worktrees alive at the start of the day. The `homefit-cleanup-worktrees` skill exists for this. Worth a sweep before the next big wave.

## Lessons / gotchas

- **iOS Reduce Motion is silent.** Spent 9 attempts on the circuit animation before realising Carl had Reduce Motion enabled. The `@media (prefers-reduced-motion: reduce)` block in our CSS correctly kills the animation, but the system setting toggle has no UI hint — animation just disappears with no error, no log, nothing. Always check the system setting first when "works on desktop but not iPhone."

- **html2canvas ignores `object-fit` and `object-position`.** That's why the PDF squashed portraits. The fix shape — pre-crop the IMG to a square data URL via canvas before rendering — makes the entire `object-fit` workaround unnecessary and structurally prevents the bug class from recurring.

- **Modal-stacking gotcha: `useRootNavigator: true` on a child sheet whose parent uses the local navigator pushes the child onto an unreachable navigator scope.** Tap fires haptic + callback fires, but no visible modal. Match the parent sheet's nav scope. PR #357 had set the flag intending to layer over the progress sheet; the bug was that the progress sheet itself uses the local navigator, so the child should too.

- **Test-scripts index.html cascade conflict on every parallel PR.** Both PR #362 and PR #364 added a top-of-list entry; the second to merge picked up the conflict. The `homefit-resolve-test-script-index` skill exists specifically for this. The load-bearing rule (per `gotcha_test_scripts_index_cascade.md`): re-grep for conflict markers AFTER `git add` — git accepts commits by index state, not file content, so markers can silently ship if you skip the re-grep.

- **Hero crop is an OVERLAY, not a saved file.** The `heroCropOffset` field is just a 0..1 number. The underlying JPG stays at the source frame's native aspect ratio (portrait / landscape / square). Every consuming surface applies the crop at render time. That's why a centralised resolver is the right shape — each surface needs the same answer.

## Fresh-session handoff

**READ FIRST:** this file (`docs/CHECKPOINT_2026-05-16.md`). It captures all five PRs merged today, the hero-resolver architecture decision and its enforcement, the skills wave, the memory entries added, and the open follow-ups.

**Carl's iPhone is on staging `5e107f8`** — install confirmed at 11:00 UTC. App is `studio.homefit.app.dev`, ENV=staging. Open the homefit.studio icon to test PR #362 (publish diagnostic surface) and PR #361 (circuit attempt #10, may already be verified).

**Working tree state when next session opens:** the origin repo at `/Users/chm/dev/TrainMe` is on branch `fix/studio-replace-pill-restore-reorder` with two uncommitted modified files (`app/lib/widgets/studio_exercise_card.dart` + `app/lib/screens/studio_mode_screen.dart`). These are partial Replace-pill changes from the killed agent. Either restore them and ship the pill, or `git restore` and start over. Branch base is `5e107f8` (today's staging tip).

**If Carl asks "what about that long-press regression"** — point at follow-up item #1 above. The fix shape is locked (drop the InkWell long-press + add a Replace pill above Rotate, same coral-pill pattern). Just needs a fresh agent run or a manual completion of the uncommitted work.

**If Carl asks about the PDF squashing portraits** — the fix shipped via PR #364 today. `staging.session.homefit.studio` auto-deployed. PDF exports should now show correctly-cropped 1:1 heroes that honour the practitioner's chosen crop offset.

**If Carl asks about Vercel spend** — the new `homefit-vercel-spend` skill exists for this. PR #364 + #365 both touched web-player and triggered staging redeploys; PR #363 was main (no web). MTD snapshot not run today.

**If Carl asks where the new skills came from** — a research agent scanned the last two weeks of session transcripts looking for recurring multi-step rituals (build + install + test, write checkpoint, direct-to-main commit, etc.). 9 strong candidates emerged; all 9 were built and installed in parallel today. The skills encode 15+ memory rules between them.
