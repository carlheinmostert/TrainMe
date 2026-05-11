# CI/CD — Release Pipeline

How code, schema, and deploys flow from "Claude wrote a thing" to "real users see it." This is the canonical CI/CD strategy doc — the staging environment is one gate in the pipeline, not the subject.

> **Status (2026-05-11):** This describes the **target** model. Schema baseline migration is committed to `main` (`supabase/migrations/20260511065443_baseline.sql`). Supabase Branching is not yet enabled on the prod project, the persistent `staging` git branch doesn't exist yet, and Vercel + Flutter aren't wired for per-branch env resolution. The "Setup status" section at the bottom tracks the cutover.

## Table of Contents

1. [Why we have staging](#1-why-we-have-staging)
2. [The three-tier model](#2-the-three-tier-model)
3. [Lifecycle of a feature](#3-lifecycle-of-a-feature)
4. [Branch naming](#4-branch-naming)
5. [Per-branch testing — both surfaces, isolated](#5-per-branch-testing--both-surfaces-isolated)
   - [Web](#web)
   - [Phone](#phone)
   - [What this gets you](#what-this-gets-you)
6. [Promotion: staging → main](#6-promotion-staging--main)
7. [Hotfixes](#7-hotfixes)
8. [Automation](#8-automation)
   - [Workflow files](#workflow-files)
   - [Custom-rule scripts](#custom-rule-scripts)
   - [Grandfathered debt](#grandfathered-debt)
   - [Where to look when CI fails](#where-to-look-when-ci-fails)
   - [Adding a new check](#adding-a-new-check)
9. [Caveats and FAQs](#9-caveats-and-faqs)
10. [Setup status (cutover checklist)](#10-setup-status-cutover-checklist)
11. [Related conventions](#related-conventions)

---

## 1. Why we have staging

Once Melissa is using the app and TestFlight builds are out, every push to `main` can no longer auto-touch real users. We need an explicit gate between "iteration" and "production."

Staging is that gate. It's a permanent holding lane where merged features accumulate, get tested together, and only reach prod when we deliberately approve the bundle. Same speed of iteration as before — just with one extra checkpoint that costs roughly nothing in time but eliminates the "I broke prod with a one-line PR" failure mode.

The mental model: **a release train.** Features board at staging. The train departs to prod when we say it does, not when each commit happens.

## 2. The three-tier model

Three layers, each running across four dimensions: git, Supabase, Vercel, and the mobile app.

```
                  ┌──────────────────────────────────────────────────────┐
                  │  PRODUCTION                                          │
                  │  ──────────                                          │
    GIT           │    main                                              │
    SUPABASE      │    "Production" branch DB  (= prod,                  │
                  │     project yrwcofhovrcydootivjx)                    │
    VERCEL        │    manage.homefit.studio + session.homefit.studio    │
    MOBILE        │    TestFlight + App Store builds (ENV=prod)          │
                  └────────────────────────▲─────────────────────────────┘
                                           │
                                           │  PROMOTE
                                           │  (deliberate "ship it" PR
                                           │   from staging → main)
                                           │
                  ┌────────────────────────┴─────────────────────────────┐
                  │  STAGING  (the release-train holding lane)           │
                  │  ─────────                                           │
    GIT           │    staging   ← persistent branch, never deleted      │
    SUPABASE      │    persistent "staging" branch DB                    │
    VERCEL        │    staging.manage.homefit.studio (custom subdomain)  │
    MOBILE        │    install-sim.sh / install-device.sh (ENV=staging)  │
                  └─────▲────────────▲────────────▲───────────────────────┘
                        │            │            │   PR merge
                        │            │            │   (one feature lands)
                  ┌─────┴────┐ ┌─────┴────┐ ┌─────┴────┐
                  │ feat/add │ │ fix/photo│ │ chore/X  │  ← FEATURE BRANCHES
                  │ -projects│ │ -spinner │ │          │     (named by Carl)
                  ├──────────┤ ├──────────┤ ├──────────┤
    SUPABASE      │ per-PR DB│ │ per-PR DB│ │ per-PR DB│  ← auto-spun, ephemeral
    VERCEL        │ PR URL   │ │ PR URL   │ │ PR URL   │  ← *.vercel.app preview
    MOBILE        │ branch   │ │ branch   │ │ branch   │  ← install scripts inject
                  │ build    │ │ build    │ │ build    │     branch-specific URL
                  └──────────┘ └──────────┘ └──────────┘
```

Three things to absorb about the shape:

1. **Vertical = promotion.** Code and schema migrations only flow upward. The only way prod changes is via the explicit `staging → main` PR.
2. **Horizontal = parallelism.** Many features in flight at once is normal. Each has its own preview URL and (if it touches schema) its own DB. They never see each other until they land in staging.
3. **Staging is permanent.** It accumulates merged features. You can leave it cooking with three things merged in, test them together, and only promote when the bundle is ready. If something in staging turns out wrong, revert it from staging — prod was never touched.

## 3. Lifecycle of a feature

```
1.  Carl: "let's fix the photo spinner"

2.  Claude: "Branch name? Suggesting `fix/photo-spinner-stuck`. OK?"
            ── pause for green light ──

3.  Carl: "yes"  (or: "make it `fix/spinner-jam`")

4.  Claude: creates worktree on that branch, writes code, opens PR
                          targeting staging   ← key: NOT main

5.  Vercel:   auto-deploys https://homefit-web-portal-git-fix-photo-...vercel.app
    Supabase: auto-creates a feat-branch DB if schema changed;
              otherwise the preview just inherits staging's schema

6.  Test in the preview URL (web) and via install scripts (phone)

7.  Carl: "merge it"

8.  PR merges → staging
    ├─ staging.manage.homefit.studio gets the new code
    ├─ staging branch DB gets the new migration applied
    └─ feature branch DB + preview URL get cleaned up

9.  (other feature branches land in staging the same way, in parallel)

10. When ready to ship:
    Claude: "Open a release PR `staging → main`? Here's what's in it:
             3 commits, X, Y, Z."
    Carl:   reviews cumulative diff, "merge"

11. PR merges → main
    ├─ manage.homefit.studio + session.homefit.studio deploy
    ├─ prod DB applies the staged migrations
    └─ next mobile build off main is shippable to TestFlight
```

## 4. Branch naming

Carl names the branch at the start of every coding task. No auto-generated names for PR-bound work.

| Prefix    | Use for                                       | Example                  |
|-----------|-----------------------------------------------|--------------------------|
| `feat/`   | New functionality                             | `feat/projects-schema`   |
| `fix/`    | Bug fix                                       | `fix/photo-spinner-jam`  |
| `chore/`  | Refactor, dependency bump, dead-code sweep    | `chore/dead-code-sweep`  |

Rules:
- Lowercase, dashes, 2–5 words after the prefix.
- Skip vague adjectives ("new", "fix", "update").
- Docs never get a branch — they go straight to `main` per the [specs-direct-to-main rule](#related-conventions).
- Sub-agent worktrees (`claude/<adjective>-<noun>-<hash>`) are fine for ephemeral background tasks that don't open a PR. For anything that's going to be a PR, the branch name is Carl's.

## 5. Per-branch testing — both surfaces, isolated

You don't have to merge into staging to test a feature. Each branch is end-to-end isolated.

### Web

Vercel auto-deploys every git branch to its own preview URL, and Supabase Branching auto-spins a branch DB. The moment you push `feat/X`:

```
git push feat/X
        │
        ▼
Vercel:    homefit-web-portal-git-feat-x-carlheinmosterts.vercel.app
Supabase:  feat/X branch DB (auto, ephemeral)
           wired together by the per-branch env vars
```

Open that preview URL on a laptop and you're testing `feat/X` against its own data. Won't touch staging. Won't touch prod.

### Phone

The mobile app isn't hosted — it's a build that ships bytes to your phone. So testing `feat/X` on iPhone needs a build-time switch. The install scripts learn to read the current git branch and inject the matching Supabase URL:

```
   Carl:   git checkout feat/X
           ./install-device.sh
                   │
                   │  script reads current git branch ("feat/X"),
                   │  queries Supabase Management API for the
                   │  feat/X branch DB URL + anon key,
                   │  builds Flutter with:
                   │    --dart-define=ENV=branch
                   │    --dart-define=SUPABASE_URL=<feat-x-db-url>
                   │    --dart-define=SUPABASE_ANON_KEY=<feat-x-anon-key>
                   ▼
   iPhone: homefit-studio (debug build) pointed at feat/X branch DB
```

So `ENV` becomes a three-way:

| `ENV` value | Resolves to                            | Used by                                |
|-------------|----------------------------------------|----------------------------------------|
| `prod`      | Prod Supabase (`yrwc...`)              | TestFlight + App Store builds          |
| `staging`   | Persistent staging branch DB           | Manual "test against staging" builds   |
| `branch`    | Current git branch's branch DB         | `install-sim.sh` / `install-device.sh` default |

Both `install-sim.sh` and `install-device.sh` default to `ENV=branch`. The TestFlight build script sets `ENV=prod` explicitly.

### What this gets you

```
   feat/X branch                feat/Y branch              staging                 main (prod)
   ─────────────                ─────────────              ───────                 ───────────
laptop:  preview URL     │   laptop:  preview URL    │   laptop:  staging.*     │  laptop:  prod
iPhone:  install         │   iPhone:  install        │   iPhone:  install       │  iPhone:  TestFlight
         (your build)    │            (your build)   │            (your build)  │
DB:      feat/X DB       │   DB:      feat/Y DB      │   DB:      staging DB    │  DB:      prod DB
         (empty,         │            (empty,        │            (release-     │           (real users)
          your fixtures) │             your fixtures)│             candidate)    │
```

Two features under simultaneous review is normal — `feat/X` running on a browser tab, `feat/Y` running on the phone — with totally separate data. Or both surfaces on `feat/X` checking [R-10 mobile↔web parity](#related-conventions).

## 6. Promotion: staging → main

The release PR is the one moment where prod changes. Treat it deliberately.

When staging has accumulated a coherent bundle (a handful of related features, all tested), Claude opens a `staging → main` PR with a summary of what's in it. The PR diff is the cumulative work since the last promotion. Carl reviews. Merging applies in one shot:

- Vercel deploys `manage.homefit.studio` and `session.homefit.studio` from the new main.
- Supabase applies all queued migrations to the prod branch DB.
- The next Flutter build off main becomes the new TestFlight candidate.

If the release PR diff looks too big or has unrelated work, push back: "split this." It's fine to do two promotions in a day. It's not fine to merge a 40-commit bundle without reading it.

## 7. Hotfixes

Some bugs need to skip the queue. The discipline still applies — through staging, not direct to main — unless staging is itself broken.

**Normal hotfix:**
1. Branch `fix/critical-X` off `main` (not off `staging`, to avoid pulling in WIP).
2. PR into `staging` like any other fix.
3. Immediately open the `staging → main` release PR with just that fix.
4. Merge both PRs back-to-back. Done in 10 minutes.

**Skip-staging hotfix** (only when staging itself is broken or holding unmergeable WIP):
1. Branch `fix/critical-X` off `main`.
2. PR directly into `main`. Get it merged.
3. **Back-merge `main` into `staging` immediately** so staging stays a true superset of prod. If you don't, the next staging migration may collide with the hotfix migration.
4. Document the skip in the PR body so future-Claude knows the divergence happened.

## 8. Automation

CI is wired in `.github/workflows/`. Every push to any branch and every PR
exercises the lint / typecheck / build / rule layer; migration files trigger
a separate Postgres-in-CI apply pass; PRs into `main` (release-train
promotions) post an auto-generated summary comment.

### Workflow files

| File | Trigger | What it does | Why we have it |
|------|---------|--------------|----------------|
| `.github/workflows/ci.yml` | every push, every PR | Six parallel jobs: `data-access-seams` (Python seam guard), `custom-rules` (bash scripts), `flutter-app` (analyze + test), `flutter-build-ios` (debug build, gated to `app/**` changes), `web-portal` (lint + typecheck + build), `web-player` (`node --check`). | The fast surface gate. Catches 90% of regressions before review. |
| `.github/workflows/migration-check.yml` | push/PR touching `supabase/migrations/**` | Spins up `postgres:17` in a container, pre-seeds the Supabase scaffolding (auth/storage/vault stubs + pgcrypto), then applies every migration file in alphabetical order via `psql -v ON_ERROR_STOP=1`. Also runs `check-migration-column-preservation.sh`. | Branching applies migrations on every per-PR DB spin-up. A broken migration means no preview DB. This catches it before the GitHub-Supabase integration tries. |
| `.github/workflows/branch-name-check.yml` | PR opened / edited / synchronize | Verifies the branch matches `^(feat\|fix\|chore)/[a-z0-9-]+$` or is `staging`. Posts a soft nudge comment when it doesn't; never fails the build. | Encourages the convention from §4 without blocking work. Auto-generated `claude/*` and `worktree-agent/*` branches are exempt. |
| `.github/workflows/release-notes.yml` | PR opened/synchronize targeting `main` | Computes the cumulative diff base...head and posts (or updates) a single PR comment with: files-changed-per-surface table, new migration filenames, full commit log. | The release PR is the only moment prod actually changes. Carl reads this comment as the change summary before merging. |
| `.github/workflows/web-player-drift-guard.yml` | every push, every PR | Existing guard that runs `tools/check_web_player_drift.py` to prevent the mobile + web player surfaces from diverging on the shared bundle. | R-10 parity rule. Pre-existing; documented here for completeness. |

### Custom-rule scripts

Two flavours live in `scripts/ci/` (bash) and `tools/` (Python). The Python
checker is richer and authoritative; the bash scripts are the lightweight
brief-shape gates wired to the `custom-rules` job.

| Script | Rule it enforces | Source-of-truth memory | Mode |
|--------|------------------|------------------------|------|
| `tools/enforce_data_access_seams.py` | All Supabase access goes through the per-surface access layer. | `feedback_no_direct_db_access.md` | Hard fail |
| `scripts/ci/check-no-direct-db-access.sh` | Same rule, lightweight bash variant. Reads grandfather list from `scripts/ci/db-access-exceptions.txt`. | `feedback_no_direct_db_access.md` | Hard fail |
| `scripts/ci/check-migration-column-preservation.sh` | Flags every `CREATE OR REPLACE FUNCTION ... RETURNS TABLE` in a migration diff and asks the reviewer to verify no prior column was dropped. | `feedback_schema_migration_column_preservation.md` | Soft nudge (GitHub `::warning::`) |
| `tools/check_web_player_drift.py` | The mobile + web-player surfaces stay in lockstep on shared bundle files. | R-10 (`docs/CI.md` §3, CLAUDE.md "Mobile ↔ Web Player Parity") | Hard fail |

Exceptions to the data-access rule live in two places, both grandfathered to
the empty state at the moment this section landed:

- `tools/data_access_seam_exceptions.json` — line-anchored exceptions for the
  Python checker. Match key is `rule|path|line|content`.
- `scripts/ci/db-access-exceptions.txt` — file-anchored exceptions for the
  bash checker. One repo-relative path per line; `#` starts a comment.

### Grandfathered debt

When a rule lands, the codebase may already have violations. Failing CI on
day one would force a giant unfocused refactor PR. Instead we capture each
existing violation in the rule's exceptions file with a comment explaining
the carve-out, then fail only on **new** violations. The exceptions file
becomes the punch list to pare down over time.

Hard rules for the exceptions files:

1. **TODO header at the top: "Pare down over time. Goal: empty file."**
   Both files have it. Don't remove it.
2. **Every entry has a comment justifying it.** Future Claude shouldn't
   need to dig through git history to know why a file was carved out.
3. **Delete the entry in the same PR that fixes the underlying call.** A
   regression caught by the rule reactivates the entry, but a stale entry
   silently weakens the rule.
4. **CI surfaces stale entries.** The Python checker prints
   `Stale allowlist entries detected (safe to remove)` for entries whose
   pattern no longer matches any real code. Clean those up when you see them.

Today both files are clean. If that changes, the goal is back to empty.

### Where to look when CI fails

| Symptom | First place to look |
|---------|---------------------|
| `data-access-seams` job red | `tools/enforce_data_access_seams.py` output → the new file/line. Route through `api_client.dart` / `api.ts` / `api.js` or add a justified entry to `tools/data_access_seam_exceptions.json`. |
| `custom-rules` job red | The script that failed prints `file:line` for each violation. Same fix as above; bash exceptions go in `scripts/ci/db-access-exceptions.txt`. |
| `flutter-app` analyze red | `cd app && flutter analyze` locally; the output matches CI verbatim. |
| `flutter-build-ios` red but `flutter-app` green | A Swift / Xcode / signing issue, not a Dart one. `cd app && flutter build ios --debug --no-codesign --dart-define=GIT_SHA=test` reproduces. |
| `web-portal` lint or typecheck red | `cd web-portal && npm run lint && npm run typecheck`. The build step also runs to catch errors lint misses; missing env vars at build time will say `Error: Environment variable not found:` — the workflow passes placeholders for that. |
| `web-portal` build red but lint+typecheck green | Likely a Next.js build-time error (RSC boundary, missing env, dynamic import). Reproduce with `npm run build`. |
| `web-player` red | `node --check` failed on one of the JS files. Output names the file + line. |
| `migration-check` apply step red | Read the psql error in the `Apply migrations in order` step. Most common cause: missing `BEGIN/COMMIT` wrapper, or referring to a role/extension the seed step doesn't install. Update the seed step rather than the migration if it's a Supabase-only built-in. |
| `release-notes` red | The compose step is a bash heredoc; check that `git diff --name-only` succeeded. Most likely cause is a shallow checkout — verify `fetch-depth: 0` is set. |
| `branch-name-check` posted a nudge but didn't fail | Working as designed. Rename and force-push, or ignore. |

### Adding a new check

When a memory note crystallises a rule, lift it into CI:

1. **Write the bash script** under `scripts/ci/`. Header comment names the
   memory note that motivates the rule. `set -euo pipefail`, `chmod +x`,
   `bash -n` clean. Print `file:line:` context on failure.
2. **Wire it into `.github/workflows/ci.yml`**. Add one step to the
   `custom-rules` job. Name the step `Custom: <rule>`.
3. **Document it here** — append a row to the script table above, plus a
   row to the `Where to look when CI fails` table.
4. **Initialise the exceptions file** (if the rule needs one) with the
   TODO header and any existing violations the first run surfaces. Commit
   the script and the exceptions file in the same PR.
5. **Update `scripts/ci/README.md`** so a fresh reader of just that
   directory understands the new rule.

For Python-side checkers (richer enforcement) follow the same pattern under
`tools/`, with exceptions in `tools/<rule>_exceptions.json`. Wire into the
`data-access-seams` style of its own job.

## 9. Caveats and FAQs

**Q: Branch DBs start empty. How do I test against realistic data?**

The first time you test `feat/X` on either surface, you'll need to create a test practice / client / plan. Two options:

- **Live with it.** Creating one test client takes 30 seconds. Fine for most feature work.
- **Seed fixtures.** Write a `supabase/seed/staging-seed.sql` that creates a known test practice + client + plan. Branch DBs run it on creation. More setup; every branch starts with realistic data. Add this only when manual setup gets annoying.

**Q: What happens to my test data when a feature branch closes?**

The Supabase branch DB is deleted with the PR. Anything you created in it is gone. So don't accumulate "test plans worth keeping" in feature branch DBs — those should live in staging.

**Q: Do I need to merge to staging to test on phone?**

No. The phone build uses the branch's own DB via the `ENV=branch` flag. The whole point of the model is per-branch isolation across both surfaces.

**Q: What about Edge Functions?**

Supabase Branching includes Edge Functions per branch. The `payfast-webhook` and any future Functions get isolated copies on feature branches. Deploys happen automatically on push.

**Q: What about Vault secrets (`supabase_jwt_secret`, `supabase_url`)?**

Vault secrets are NOT replicated to branch DBs automatically — they're environment-specific values. The baseline migration's §12 lists the `vault.create_secret` calls. After Branching is enabled, we'll need a one-time GitHub Action that populates vault secrets per branch on creation. Until that's in place, features that depend on `sign_storage_url` (any signed-URL generation) won't work on feature branch DBs — that's a known limitation we accept until the Action exists.

**Q: How does Supabase Branching know which migrations to apply?**

It reads `supabase/migrations/*.sql` (in timestamp order). Every schema change after the baseline is a new dated file. Run `supabase migration new <name>` to create one. Do NOT use `supabase db query --linked` for schema changes anymore — that bypasses the migration chain and breaks Branching.

**Q: What if I'm on a branch and need to pull a fix that landed in staging?**

`git pull origin staging` into your feature branch. Standard git. Same for `main` if staging hasn't caught up yet.

## 10. Setup status (cutover checklist)

What's done:

- [x] Schema baseline migration committed (`supabase/migrations/20260511065443_baseline.sql`, commit `29277ac`).
- [x] Migrations README documenting the convention (`supabase/migrations/README.md`).
- [x] Standalone `homefit.studio-staging` Supabase project created (`txxprpxlumstzxjnbtuo`) for one-time validation.
- [x] Memory rules: staging vocabulary, branch naming, specs-direct-to-main, APIs-not-dashboards.

What's pending:

- [ ] Apply baseline to standalone staging project. Smoke-test that the web-portal + web-player + mobile app boot against it. Validates the baseline is complete.
- [ ] Enable Supabase Branching on the prod project. Connect GitHub integration.
- [ ] Create persistent `staging` git branch off `main`. Supabase auto-creates the matching persistent branch DB.
- [ ] Configure Vercel: assign `staging.manage.homefit.studio` + `staging.session.homefit.studio` subdomains to the `staging` branch. Wire env vars so feature-branch previews talk to their auto-spun branch DBs.
- [ ] Update DNS at Hostinger: `staging.manage.homefit.studio` + `staging.session.homefit.studio` CNAMEs.
- [ ] Add Flutter `ENV` flag. Branching in `app_config.dart`. Default `ENV=branch` in install scripts; explicit `ENV=prod` in TestFlight build scripts.
- [ ] Branch-aware install script: parse current git branch, query Supabase Management API for the matching branch DB URL + anon key, inject via `--dart-define`.
- [ ] One-time GitHub Action to populate vault secrets on branch creation.
- [ ] Decommission standalone staging project once Branching cutover is validated.
- [ ] Archive `supabase/schema_*.sql` files to `supabase/archive/` once Branching is live.

## Related conventions

- [docs/BACKLOG.md](BACKLOG.md) — deferred / future work.
- [CLAUDE.md](../CLAUDE.md) — project overview and architecture.
- Memory: "Specs + docs go directly to main" — docs never get a feature branch.
- Memory: "No direct DB access — RPCs only" — every read/write goes through the per-surface access layer.
- Memory: "Schema migrations must preserve all RPC columns" — when re-creating an RPC via `CREATE OR REPLACE FUNCTION`, source the live definition first.
- R-10 mobile↔web parity — applies inside a feature branch too; both surfaces must update together.
