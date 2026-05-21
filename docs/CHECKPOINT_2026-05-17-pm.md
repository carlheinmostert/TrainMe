# Checkpoint — 2026-05-17 PM — Staging → main promotion, prod sev1 hotfix, TestFlight build 4

**The morning was device-QA polish (covered in `docs/CHECKPOINT_2026-05-17.md`); the afternoon pivoted to shipping six days of staging work to prod, fixing a sev1 portal crash that the promotion smoke surfaced, backporting that fix to staging, and queueing a fresh TestFlight build.** The release pipeline carried 95 PRs from `v2026-05-11.1` to `v2026-05-17.1`, but the new strict-fail env-var helpers (PRs #293/#307/#308) used dynamic `process.env[name]` bracket access — Webpack never inlines that pattern into client bundles, so every authenticated route on `manage.homefit.studio` threw a "client-side exception" the moment the SignInGate's `supabase-browser.ts` loaded. Diagnosis spent ~25 minutes blaming missing Vercel env vars (set them but they got locked at empty by Vercel's "sensitive" default — second gotcha of the day) before finding the real Webpack issue. Hotfix landed direct to main with Carl's explicit authorization, backport to staging shipped as PR #388. Day closed with the TestFlight `1.0.0+4` build queued for Apple processing.

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [PR sequence](#pr-sequence)
- [Memory rules added today](#memory-rules-added-today)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Main tip:** `1cb555e` — `docs(test-scripts): add 2026-05-17 prod-promotion smoke wave + index entry`. Three commits past this morning's `fa6af09`: the release squash (`eeaa7ea` = [#387](https://github.com/carlheinmostert/TrainMe/pull/387)), the env.ts hotfix (`9c813f2`), and the test-script docs (`1cb555e`).
- **Staging tip:** `b219370` — `fix(portal): backport env.ts literal-process.env hotfix to staging (#388)`. One commit past `0329d12`. Staging is now in sync with main on the load-bearing code; the docs commits stay main-only.
- **Tag:** `v2026-05-17.1` — landed manually after the squash-merge of #387 because the `release-tag.yml` workflow gates on `startsWith(github.event.head_commit.message, 'Merge pull request')` and a squash-merge writes the PR title as the subject. Worth tightening the workflow.
- **Carl's iPhone CHM:** still on the dev-signed `eeaa7ea` build installed via `./install-device.sh prod` (the prod-promotion smoke walk). TestFlight `1.0.0+4` (build SHA `1cb555e`) is queued at Apple — once processed, Carl will install via the TestFlight app, which is the real release-signed distribution path.
- **Vercel deploys today:** ~30 portal + ~30 player (the staging-train + the prod-promotion deploys + two prod redeploys for the env-var failed attempts + the actual hotfix redeploy + the post-`1cb555e` rebuild). All in the Pro+ included quota; spend snapshot has a placeholder marker because the v1/usage Vercel API is 404. Carl can peek `https://vercel.com/teams/carlheinmosterts-projects/settings/billing` for a real number next session.
- **Vercel env vars on `homefit-web-portal`:** all four `NEXT_PUBLIC_*` URL vars now set with `type: encrypted` (NOT `sensitive`) across {production, preview}. Validated via API after the sensitive-vars trap cost ~10 min mid-session.
- **Supabase Branching:** staging branch DB at the b219370 tip (re-applies are no-ops; no new migrations today). Prod DB has all 7 migrations from the release.
- **Blocked on Carl (unchanged from this morning):** Hostinger 301 redirects (`homefit.studio/privacy|terms` → `manage.homefit.studio/...`); `support@homefit.studio` mailbox; ZA lawyer red-pen of privacy/terms scaffold; PayFast production merchant account.

## The day's big decisions

Five load-bearing decisions, each surfaced live by the work in front of us.

1. **Promote staging → main as a single 95-PR squash, even though it spans three checkpoints.** Six days of staging work (2026-05-15 / 16 / 17) all bundled into PR #387. Pre-merge sanity flagged 7 schema migrations + 3 re-creations of `get_plan_full` + 1 each of `list_practice_clients` and `set_client_video_consent` — all called out in the PR body per the `feedback_sensitive_code_review_before_merge` rule. The squash-merge created a clean commit on main but skipped the auto-tag workflow (gates on `"Merge pull request"` subject); landed `v2026-05-17.1` manually. The auto-tag gate needs to recognise squash-merges as a follow-up.

2. **Conflict resolution on the release branch had to bump SQLite DB version 39 → 42.** Both branches incremented past v38 simultaneously: staging used v39 for `consent_explicitly_set_at`, then v40 for `thumbnails_dirty`, then v41 for the photo `_thumb_bw.jpg` stamp. Main got PR #363 (direct merge to main, not via staging) which also used v39 for `practice_id` on local sessions. Cherry-pick → version collision. Resolved by renumbering main's `practice_id` migration to v42; all four migrations now ship in deterministic order with idempotent `_addColumnIfMissing` so the order doesn't actually matter at runtime, but the deterministic chain matters for `pg_dump`-style baselining. The idempotent_migration_test bumped its `user_version` assertion to 42.

3. **Sev1 prod-portal crash on `manage.homefit.studio` is a Webpack-inline bug, not a missing-env-var bug.** Surfaced by Carl walking item 9 of the prod-promotion smoke (`docs/test-scripts/2026-05-17-prod-promotion-smoke-device-qa.html`). The new `web-portal/src/lib/env.ts` from PRs #293/#307/#308 wrote `const value = process.env[name]` inside `requireEnv` — bracket-notation dynamic access. Webpack's DefinePlugin only inlines `NEXT_PUBLIC_*` env vars when the access is a static literal (`process.env.NEXT_PUBLIC_FOO`); dynamic access leaves the runtime lookup against `process.env`, which is an empty object in the browser. Every client module that loaded `supabase-browser.ts` (the SignInGate's transitive import) threw at module-evaluation time. The sign-in page rendered briefly (server-rendered HTML), then the client bundle hydrated and React's error boundary caught the throw. Fix at `web-portal/src/lib/env.ts:47-63` + 4 helper call sites: `requireEnv` now takes a pre-read `value` parameter, each helper does the literal `process.env.NEXT_PUBLIC_X` at the call site so Webpack inlines.

4. **Direct-to-main hotfix with explicit authorisation.** Carl approved with "push to main" rather than the conventional staging route, given the sev1 nature. Auto-classifier blocked the first `git push origin main` attempt at the env.ts hotfix; second attempt succeeded after Carl's explicit consent. Commit `9c813f2`. Verified by chunk-hash inspection: chunk `272-6c312da2c84ae0bb.js` (new content hash post-fix) now contains the inlined `yrwcofhovrcydootivjx` (Supabase URL) + `session.homefit.studio` (web player base URL) + `createBrowserClient` SDK call site. The OLD chunk had none of these strings — confirmation that Webpack inlining is finally working.

5. **Backport to staging via PR #388, not direct push.** Main is ahead of staging by the hotfix commit. Without backporting, the next staging deploy reproduces the bug. Classifier blocked direct push to staging from an ad-hoc local branch (the rule applies symmetrically to both protected branches). Reframed as a `fix/portal-env-literal-reads-backport` branch + PR against staging — disciplined path, took 90 seconds to author, merged + auto-deployed to `staging.manage.homefit.studio` within 5 minutes.

## PR sequence

| # | PR | Title | Why |
|---|---|---|---|
| 1 | [#387](https://github.com/carlheinmostert/TrainMe/pull/387) | `release: 2026-05-17 — 95 PRs since 2026-05-11 (publish refactor + cache stack + studio polish)` | The staging→main promotion. 95 PRs spanning checkpoints 2026-05-15 / 16 / 17. 7 schema migrations, 3 re-creations of `get_plan_full`. Squash-merged at `eeaa7ea`. |
| 2 | direct | `fix(portal): env.ts must use literal process.env reads so Webpack inlines NEXT_PUBLIC_*` | Commit `9c813f2`. Sev1 hotfix on top of #387. Made `requireEnv` take a pre-read value; each helper does literal `process.env.NEXT_PUBLIC_X` so Webpack inlines. Direct-to-main with Carl's explicit authorisation. |
| 3 | direct | `docs(test-scripts): add 2026-05-17 prod-promotion smoke wave + index entry` | Commit `1cb555e`. Test script at `docs/test-scripts/2026-05-17-prod-promotion-smoke-device-qa.html` + index entry at top of "test these now". Item 9 surfaced the env.ts bug. |
| 4 | [#388](https://github.com/carlheinmostert/TrainMe/pull/388) | `fix(portal): backport env.ts literal-process.env hotfix to staging` | Cherry-pick of `9c813f2` onto staging so the next staging deploy doesn't reproduce the prod bug. Squash-merged at `b219370`. |

Also out-of-band:

- Manual tag `v2026-05-17.1` on `eeaa7ea` (the auto-tag workflow didn't fire on the squash-merge subject).
- 4 Vercel env vars set/reset on `homefit-web-portal` ({production, preview} × {`NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_WEB_PLAYER_BASE_URL`}). Initial CLI attempts created them as `type: sensitive` (immutable, value-locked at empty); the correct invocation is `vercel env add NAME ENV --value "X" --no-sensitive --yes` OR direct API POST with `target: [ENV]` and no `gitBranch` field.
- TestFlight build `1.0.0+4` (build SHA `1cb555e`) archived in Xcode and uploaded via Organizer's Distribute → App Store Connect flow. Apple processing queued at session end. Build numbering walked through `+3` (collision with the actual May 5 uploaded build — the project memory was wrong about "+1 was the May 5 upload"; Organizer history shows +1 failed, +2 + +3 both uploaded).

## Memory rules added today

- [Webpack only inlines literal process.env.NEXT_PUBLIC_X](../.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_webpack_inline_dynamic_env.md) — Bracket-notation access is NEVER inlined. Helpers wrapping env reads must take the value as a param, not look it up internally.
- [Vercel sensitive env vars are value-immutable once created](../.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_vercel_sensitive_env_vars.md) — Default for production+preview. Use `--no-sensitive --value "X"` for `NEXT_PUBLIC_*` vars or you get locked at empty.

Worth adding next session (didn't capture today):

- `gotcha_flutter_pubget_no_xcconfig_refresh.md` — `flutter pub get` updates packages but does NOT refresh `FLUTTER_BUILD_NUMBER` in `app/ios/Flutter/Generated.xcconfig` from a changed `pubspec.yaml`. Use `flutter build ios --config-only` (regenerates xcconfig in ~2s without compiling) or any full `flutter build` command. Symptom today: bumped pubspec from `+3` to `+4`, ran pub get twice, Xcode kept stamping `1.0.0 (3)` archives.

## Open follow-ups for next session

1. **Confirm TestFlight `1.0.0+4` processed.** Apple emails when ready (~15-30 min after upload). Open [App Store Connect](https://appstoreconnect.apple.com) → Apps → homefit.studio → TestFlight → confirm build appears, fill in Export Compliance if asked, add to Internal Testing group.

2. **Install `1.0.0+4` on iPhone CHM via TestFlight app** (NOT `./install-device.sh`). This is the first release-signed Apple-distributed install since 2026-05-05. Smoke check: cold launch, sign in to prod, capture + publish, open shared URL in Safari.

3. **Update `project_trainme_overview.md` memory** — currently says the 2026-05-05 TestFlight upload was `1.0.0+1`. The Organizer history shows: `+1` upload FAILED, `+2` uploaded 4 May, `+3` uploaded 5 May. Memory should reflect this.

4. **Tighten `release-tag.yml` to fire on squash-merges.** Currently gates on `startsWith(github.event.head_commit.message, 'Merge pull request')` which is the default-merge-style commit subject. Squash-merges write the PR title as the subject and skip the gate. Either widen the condition (e.g. detect any PR-bot-authored commit) or remove the gate entirely and let the workflow run on every push to main (it's idempotent — re-tagging the same SHA fails harmlessly).

5. **Capture the flutter-pubget-vs-config-only gotcha as a memory entry.** See "Memory rules added today" above for the gist.

6. **Carry forward from this morning's checkpoint:** Hostinger 301 redirects, `support@homefit.studio` mailbox, ZA lawyer red-pen, PayFast prod merchant account — all still blocked on Carl.

## Lessons / gotchas

- **A "client-side exception" with a vague React error message can take 25 min to diagnose because the chain is four layers deep.** Today's chain: (1) Vercel env vars might be missing → check + set them. (2) Set vars came back empty after `vercel env add` → discovered the CLI's stdin-prompt timing was racy. (3) Switched to `--value` flag → still came back empty. (4) Inspected via API → vars were `type: sensitive`, which is value-immutable once created. (5) Deleted + recreated as `--no-sensitive` → values stuck. (6) Redeployed prod → bug persisted. (7) Inspected chunk bytes — no inlined URLs ANYWHERE. (8) Realised `process.env[name]` is not inlinable. The right first move would have been to check the bundle for the env-var values BEFORE messing with Vercel config. "Is the bug in the env config or in the code that reads the env config" is a useful diagnostic forking question for any env-var-related crash.

- **`vercel env add` defaults to `type: sensitive` on production + preview environments.** Sensitive vars cannot have their value updated once created — the API accepts PATCH calls and returns success but silently ignores the value change. The only fix is delete + recreate. Always use `--no-sensitive --value "X" --yes` for `NEXT_PUBLIC_*` vars (they're safe to expose, never secrets). Verify post-set via the API with `?decrypt=true` and check `type: "encrypted"` (good, mutable) vs `type: "sensitive"` (immutable trap). The CLI now also requires an explicit `<gitbranch>` arg between target and `--value` non-interactively; the "omit for all branches" form errors with `git_branch_required`. Direct API POST with `target: ["production"]` (or `["preview"]`) and no `gitBranch` field gives the equivalent of "all branches in this target" and matches the legacy entry shape.

- **`flutter pub get` does NOT refresh `FLUTTER_BUILD_NUMBER` in `Generated.xcconfig`.** Pub get only updates package dependencies. The xcconfig build number is regenerated by `flutter build ios --config-only` (or any full `flutter build` command). Today's symptom: bumped pubspec from `+3` to `+4`, ran pub get twice, Xcode kept producing `1.0.0 (3)` archives because the xcconfig still said `FLUTTER_BUILD_NUMBER=3`. The fix is the `--config-only` flag — it regenerates the xcconfig in ~2 seconds without compiling anything. After running it, close + reopen the Xcode workspace so Xcode re-reads the xcconfig.

- **Release-tag automation has a squash-merge blind spot.** `release-tag.yml` gates on the commit subject starting with `"Merge pull request"`, which is the default-merge-style subject Vercel/GitHub uses for true merge commits. Squash-merges write the PR title as the subject, so the workflow's `if:` condition evaluates to false and the auto-tag silently skips. Today's manual tag landed via `git tag -a v2026-05-17.1 eeaa7ea && git push origin v2026-05-17.1`. Pin this as a CI follow-up — the squash-merge style is otherwise the cleaner default for this project, so the workflow should accommodate it.

- **Build-number collision on TestFlight requires bumping past every existing uploaded build, not just the most recent.** Today's `1.0.0+3` archive (the one Flutter just built) collided with the previous `1.0.0+3` from 5 May. Apple's "build number must be greater than existing" rejection is per-version-string; you need monotonic on the `+N` even across days. Bump to `+4`, regenerate xcconfig, archive, upload. The Xcode Organizer's Archives tab is the canonical view of what's been uploaded vs. just archived locally — useful for spotting these collisions before the upload attempt.

- **Direct-to-main + classifier interaction.** Carl's "1" reply to a multi-option question wasn't specific enough for the classifier to authorise a direct-to-main push. Took an explicit "push to main" to clear it. The pattern that works reliably: present the action verbatim, ask for the action verb back. "Say `push to main` and I'll run the push" is the shape.

## Fresh-session handoff

**READ FIRST:** this file (`docs/CHECKPOINT_2026-05-17-pm.md`). Main tip is `1cb555e`. Staging tip is `b219370`. Tag `v2026-05-17.1` is live. Both prod surfaces (`session.homefit.studio` + `manage.homefit.studio`) verified working post-hotfix; all 10 items of the prod-promotion smoke wave passed.

**Carl's iPhone is on the dev-signed `eeaa7ea` build via `./install-device.sh prod`.** The TestFlight `1.0.0+4` upload was in progress at session end. When the fresh session starts, first check: open [App Store Connect TestFlight](https://appstoreconnect.apple.com) and confirm `1.0.0 (4)` has finished processing. If it shows "Ready to Submit" or "Ready for External Testing", Carl should install via the TestFlight app on his iPhone (NOT `install-device.sh` — TestFlight is the real Apple-distribution path) and smoke-check the golden path.

**The env-var helper file (`web-portal/src/lib/env.ts`) is now the canonical pattern** for all `NEXT_PUBLIC_*` access in the portal. If you add a new env var that needs to be readable in client components, follow the existing 4 helpers' shape: literal `process.env.NEXT_PUBLIC_X` at the call site, passed into `requireEnv(name, value, placeholder)`. Webpack's DefinePlugin handles the rest.

**Staging is one commit behind main on the docs/checkpoint files** (`1cb555e` is main-only). That's intentional per the `feedback_specs_direct_to_main` rule — checkpoints don't ride the release train. Code is in sync (the env.ts hotfix is on both branches).

**The `release-tag.yml` squash-merge blind spot is a known follow-up** — manually tag releases via `git tag -a v2026-MM-DD.N <main-sha> -m "..." && git push origin v2026-MM-DD.N` until the workflow is widened.
