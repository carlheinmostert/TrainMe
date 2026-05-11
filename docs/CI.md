# CI/CD — Release Pipeline

How code, schema, and deploys flow from "Claude wrote a thing" to "real users see it." This is the canonical CI/CD strategy doc — the staging environment is one gate in the pipeline, not the subject.

> **Status (2026-05-11):** This describes the **target** model. Schema baseline migration is committed to `main` (`supabase/migrations/20260511065443_baseline.sql`). Supabase Branching is not yet enabled on the prod project, the persistent `staging` git branch doesn't exist yet, and Vercel + Flutter aren't wired for per-branch env resolution. The "Setup status" section at the bottom tracks the cutover.

## Table of Contents

1. [Why we have staging](#1-why-we-have-staging)
2. [The three-tier model](#2-the-three-tier-model)
3. [Lifecycle of a feature](#3-lifecycle-of-a-feature)
4. [Branch naming](#4-branch-naming)
5. [Per-branch testing on web and phone](#5-per-branch-testing-on-web-and-phone)
   - [Web](#web)
   - [Phone](#phone)
   - [What this gets you](#what-this-gets-you)
6. [Promoting staging to main](#6-promoting-staging-to-main)
7. [Hotfixes](#7-hotfixes)
8. [Automation](#8-automation)
   - [8.1 Layered design overview](#81-layered-design-overview)
   - [8.2 Workflows in `.github/workflows/`](#82-workflows-in-githubworkflows)
   - [8.3 Custom check scripts](#83-custom-check-scripts)
   - [8.4 External automation (Vercel, Supabase Branching)](#84-external-automation-vercel-supabase-branching)
   - [8.5 Local verification before commit](#85-local-verification-before-commit)
   - [8.6 Adding a new check](#86-adding-a-new-check)
   - [8.7 Grandfather mechanism](#87-grandfather-mechanism)
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

## 5. Per-branch testing on web and phone

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

## 6. Promoting staging to main

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

Automation lives in three layers — repo-level workflows in `.github/workflows/`, check implementations under `tools/` and `scripts/ci/`, and external services (Vercel, Supabase) that run their own automation on top of git events. Every layer has the same goal: catch a regression before a human (or a customer) does.

### 8.1 Layered design overview

The pyramid, narrow at the top:

```
   ┌─────────────────────────────────────────────────────────┐
   │  External automation (we don't operate it)              │
   │    Vercel per-branch previews, prod deploys             │
   │    Supabase Branching (pending) — per-branch migrations │
   └─────────────────────────────────────────────────────────┘
   ┌─────────────────────────────────────────────────────────┐
   │  Repo workflows  (.github/workflows/)                   │
   │    ci.yml, migration-check.yml, branch-name-check.yml,  │
   │    release-notes.yml, web-player-drift-guard.yml        │
   └─────────────────────────────────────────────────────────┘
   ┌─────────────────────────────────────────────────────────┐
   │  Check implementations                                  │
   │    tools/*.py            scripts/ci/*.sh                │
   │    tools/data_access_seam_exceptions.json               │
   │    scripts/ci/db-access-exceptions.txt                  │
   └─────────────────────────────────────────────────────────┘
```

**Belt and braces — intentional redundancy.** Two checks exist for the "no direct DB access" rule: a richer Python guard (`tools/enforce_data_access_seams.py`, line-anchored allowlist) and a lightweight bash guard (`scripts/ci/check-no-direct-db-access.sh`, file-anchored allowlist). Both run in the same `ci.yml` workflow. The Python checker is the **authoritative** one; the bash version is fast enough to use as a pre-commit hook and serves as a safety net if the Python file develops a parser bug. If the two ever disagree, treat the Python checker as canonical.

**Hard fail vs soft nudge.** A hard-fail check returns non-zero and blocks the PR — used for invariants that should never regress (data-access seams, web-player drift, branch-name conventions when violated, migration apply errors). A soft nudge prints a `::warning::` and exits 0 — used for human-review prompts where full automation would need a real parser (the `RETURNS TABLE` column-preservation check is the only one today). The branch-name workflow is also soft — it posts a PR comment but never fails the build.

### 8.2 Workflows in `.github/workflows/`

Five workflow files today. Each one is small, single-purpose, and named for what it gates.

#### `.github/workflows/ci.yml` — the surface gate

- **Triggers:** `push` to any branch, `pull_request` to any base.
- **Concurrency:** per-ref, cancel-in-progress — a new push cancels the in-flight run on the same branch.
- **Jobs (7):**
  - `data-access-seams` — runs `python3 tools/enforce_data_access_seams.py`. Hard fail on new direct-Supabase usage outside the per-surface access layer.
  - `custom-rules` — runs `scripts/ci/check-no-direct-db-access.sh` (hard) and `scripts/ci/check-migration-column-preservation.sh` (soft, with `BASE_REF` set to the PR base or `origin/main`). Needs `fetch-depth: 0` for the column-preservation diff.
  - `detect-app-changes` — one-shot `git diff` over `app/**`. Outputs `app_changed=true|false` for the downstream iOS-build gate. Treats first-push / shallow-clone cases as `true` so we never silently skip on incomplete history.
  - `flutter-app` — `flutter pub get` + `flutter analyze` + `flutter test`. Runs on `ubuntu-latest`. Depends on `data-access-seams`.
  - `flutter-build-ios` — `flutter build ios --debug --no-codesign`. Runs on `macos-latest` (expensive minutes). Gated by `needs.detect-app-changes.outputs.app_changed == 'true'` so a docs-only PR doesn't burn a mac runner.
  - `web-portal` — `npm ci` + `npm run lint` + `npm run typecheck` + `npm run build`. Build is exercised with placeholder env vars (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `APP_URL`) so the build pipeline shape is validated without real secrets. Depends on `data-access-seams`.
  - `web-player` — `node --check` on every top-level `web-player/*.js`. Catches syntax errors only (the player is static; there's no bundler to run).
- **What it catches:** unrouted Supabase calls, Dart analyzer regressions, broken Flutter test suite, iOS build breakage, Next.js lint/type/build breakage, web-player JS syntax errors.
- **Rules enforced:** `feedback_no_direct_db_access.md` (via both data-access jobs), R-08 (the iOS-build job is the iOS-build sanity check the install scripts run locally).

#### `.github/workflows/migration-check.yml` — Postgres-in-CI apply pass

- **Triggers:** `push` and `pull_request` with paths filter `supabase/migrations/**` or the workflow file itself.
- **Concurrency:** per-ref, cancel-in-progress.
- **Job:** `apply-migrations` runs on `ubuntu-latest` with a `postgres:17` service container.
  - Step 1: install `postgresql-client` and wait for the container.
  - Step 2: pre-seed required Supabase scaffolding inline via `psql -v ON_ERROR_STOP=1` — creates the `anon`, `authenticated`, `service_role`, `supabase_admin` roles; the `auth`, `storage`, `vault`, `extensions` schemas; minimal stubs for `auth.users`, `auth.uid()`, `auth.role()`, `auth.jwt()`, `storage.buckets`, `storage.objects`, `vault.secrets`, `vault.decrypted_secrets`, `vault.create_secret`; and `pgcrypto` + `uuid-ossp` + `citext` extensions. Also fakes a `pgjwt` install (real extension isn't in apt; we stub `extensions.sign` and INSERT a row into `pg_extension` so `CREATE EXTENSION IF NOT EXISTS pgjwt` is a no-op).
  - Step 3: apply every file under `supabase/migrations/*.sql` in alphabetical order with `psql -v ON_ERROR_STOP=1 -f <file>`. Fails on the first error.
  - Step 4: `scripts/ci/check-migration-column-preservation.sh` posts `::warning::` markers for any new `RETURNS TABLE` blocks.
- **What it catches:** SQL syntax errors, migration ordering bugs (file A timestamped earlier than file B but depending on it), idempotency regressions (a migration that doesn't apply cleanly to a fresh DB), references to roles or extensions the seed step doesn't install.
- **Rules enforced:** the schema baseline must apply cleanly to a fresh Postgres 17 — Supabase Branching does this on every per-PR DB spin-up; if migration-check is red, Branching will also fail. `feedback_schema_migration_column_preservation.md` is enforced as soft nudge.

#### `.github/workflows/branch-name-check.yml` — convention nudge

- **Triggers:** `pull_request` of types `opened`, `reopened`, `edited`, `synchronize`.
- **Permissions:** `pull-requests: write` (to post the nudge comment).
- **Job:** `check-branch-name` matches `head.ref` against:
  - `staging` or `main` → ok.
  - `^(feat|fix|chore)/[a-z0-9-]+$` → ok.
  - `^(claude|worktree-agent)/` → ephemeral (ok, no comment).
  - anything else → posts a PR comment with the §4 rule and a rename hint. Always exits 0.
- **What it catches:** branches like `update-foo`, `wip`, `chm/test` that bypass the §4 convention.
- **Rule enforced:** `feedback_branch_naming_discipline.md` (and §4 of this doc).

#### `.github/workflows/release-notes.yml` — promotion summary

- **Triggers:** `pull_request` of types `opened`, `reopened`, `synchronize`, **with `branches: [main]`** — only fires on staging→main release PRs.
- **Permissions:** `pull-requests: write`, `contents: read`.
- **Job:** `release-notes` computes the cumulative diff `base...head` and posts (or upserts via the `<!-- release-notes-bot -->` HTML comment marker) a single comment with: per-surface files-changed table (web-portal / web-player / app / supabase / docs / other), list of newly added migration filenames, full commit log subject lines. Needs `fetch-depth: 0` for the log.
- **What it catches:** nothing fails; the comment is informational. The point is to make Carl read the cumulative diff before merging the release train into prod.
- **Rule enforced:** §6 of this doc — the release PR is the only deliberate gate between staging and main.

#### `.github/workflows/web-player-drift-guard.yml` — R-10 lockstep

- **Triggers:** every `pull_request`, plus `push` to `main`.
- **Job:** `web-player-drift-guard` runs `python3 tools/check_web_player_drift.py`.
- **What it catches:** divergence between `web-player/*.{html,js,css}` (the canonical source) and `app/assets/web-player/*.{html,js,css}` (the bundle shipped inside the Flutter app for offline preview). The four files compared are `index.html`, `app.js`, `api.js`, `styles.css` (SHA-256 over bytes). Drift fails with a fix-it line pointing at `dart run app/tool/sync_web_player_bundle.dart`.
- **Rule enforced:** R-10 mobile↔web parity (CLAUDE.md "Mobile ↔ Web Player Parity"; §3 of this doc).

### 8.3 Custom check scripts

For each check that runs in CI, the implementation, its allowlist, and how to invoke it locally.

#### `tools/enforce_data_access_seams.py`

- **Language:** Python 3 (no third-party deps).
- **What it checks:** scans `app/lib/**/*.dart` for `Supabase.instance.client`, `web-player/**/*.js` for `/rest/v1/`, and `web-portal/src/**/*.{ts,tsx}` for `(this.)?supabase.(from|rpc|storage)(`. Skips comment lines. Skips files in the per-rule `allowed_files` set (the access-layer files).
- **Allowlist:** `tools/data_access_seam_exceptions.json` — JSON object with `last_updated` and `allowed_violations` (a list of `rule|path|line|content` strings). Currently empty.
- **Invoked by:** `.github/workflows/ci.yml` → `data-access-seams` job.
- **Manual invocation:** `python3 tools/enforce_data_access_seams.py` from repo root. Exits 0/1.
- **Memory rule:** `feedback_no_direct_db_access.md`.

#### `tools/check_web_player_drift.py`

- **Language:** Python 3 (stdlib only — `hashlib`, `pathlib`).
- **What it checks:** SHA-256 each of `index.html`, `app.js`, `api.js`, `styles.css` in both `web-player/` and `app/assets/web-player/`. Fails on any mismatch.
- **Allowlist:** none (drift is never acceptable).
- **Invoked by:** `.github/workflows/web-player-drift-guard.yml`.
- **Manual invocation:** `python3 tools/check_web_player_drift.py`.
- **Memory rule:** R-10 parity (CLAUDE.md).

#### `tools/verify-toc.py`

- **Language:** Python 3 (stdlib only).
- **What it checks:** given a Markdown file with a `## Table of Contents` section, derives a GitHub-rendered slug for every `##` and `###` heading and verifies every `[label](#anchor)` link inside the TOC resolves to a real heading slug. Empirically calibrated to GitHub's slug algorithm — including the quirk that adjacent hyphens are NOT collapsed (the em-dash + spaces in `Per-branch testing — both` become two adjacent hyphens in the slug).
- **Allowlist:** none.
- **Invoked by:** not wired into CI yet — local pre-commit only as of today. (A follow-up will add a workflow for doc files.)
- **Manual invocation:** `python3 tools/verify-toc.py docs/CI.md` (or any other `.md` file with a TOC). Exits 0/1.
- **Memory rule:** `feedback_markdown_toc.md`.

#### `scripts/ci/check-no-direct-db-access.sh`

- **Language:** bash (macOS 3.2-compatible — no associative arrays).
- **What it checks:** greps `web-portal/src/**/*.{ts,tsx}` for `supabase.(from|rpc|storage)(`, `web-player/*.js` (depth 1) for `/rest/v1/` and the same `.from/.rpc/.storage` pattern, and `app/lib/**/*.dart` for `Supabase.instance.client`. Skips obvious comment lines. Skips files in the inline allowlist (`api_client.dart`, `web-portal/src/lib/supabase/api.ts`, `database.types.ts`, `web-player/api.js`, `web-player/middleware.js`) and files under whitelisted prefixes (`web-portal/src/lib/supabase/`, `supabase/functions/`, `web-player/html2canvas.min.js`).
- **Allowlist:** `scripts/ci/db-access-exceptions.txt` — one repo-relative path per line, `#` starts a comment. Currently empty (only the TODO header). Belt-and-braces with the richer Python checker above — if the two ever disagree, the Python checker is canonical.
- **Invoked by:** `.github/workflows/ci.yml` → `custom-rules` job.
- **Manual invocation:** `scripts/ci/check-no-direct-db-access.sh`. Exits 0/1.
- **Memory rule:** `feedback_no_direct_db_access.md`.

#### `scripts/ci/check-migration-column-preservation.sh`

- **Language:** bash + an inline `awk` pass.
- **What it checks:** for every migration file changed in the current diff (defaults to `origin/main`...HEAD; override with `BASE_REF`; `--all` scans every migration), extracts each `CREATE OR REPLACE FUNCTION ... RETURNS TABLE (...)` block and prints a GitHub `::warning file=...,line=...::` nudge plus a human-readable summary block. Never fails — always exits 0.
- **Allowlist:** none — every block is flagged.
- **Invoked by:** `.github/workflows/ci.yml` → `custom-rules` job and `.github/workflows/migration-check.yml` → `Column-preservation nudge` step. Both set `BASE_REF` from the PR base.
- **Manual invocation:** `scripts/ci/check-migration-column-preservation.sh` (diff vs `origin/main`) or `scripts/ci/check-migration-column-preservation.sh --all`. The closing block shows the pre-flight commands (`psql \df+` and `SELECT pg_get_functiondef(...)`) to run against the live DB.
- **Memory rule:** `feedback_schema_migration_column_preservation.md`.

### 8.4 External automation (Vercel, Supabase Branching)

Two services run automation we don't operate but rely on. Document them so a fresh reader knows the full picture.

**Vercel — per-branch previews + prod deploys.** Both `web-portal/` and `web-player/` are wired into Vercel projects (`homefit-web-portal` and the web-player project under team `carlheinmosterts-projects`). Behaviour:

- Push to any branch → Vercel auto-deploys a preview at `<project>-git-<branch>-carlheinmosterts.vercel.app`. Build logs are visible in the Vercel UI; build errors surface on the GitHub commit status and as a check on the PR.
- Push to `main` → Vercel deploys to production aliases `manage.homefit.studio` and `session.homefit.studio`.
- Per-branch env vars: configured in the Vercel project settings. The `web-portal` build job in `ci.yml` only validates the build shape with placeholder env vars — the real values come from Vercel at deploy time. There is no GitHub Action that pushes secrets to Vercel; they live in Vercel's UI.
- Headers are pinned via `web-portal/vercel.json` and `web-player/vercel.json` (CSP, HSTS, Permissions-Policy). Changing those is a deploy-affecting change like any other.

**Supabase Branching (pending).** Once enabled on the prod project, every push to a feature branch will spin up an ephemeral branch DB. Every migration file under `supabase/migrations/` will be applied automatically — same alphabetical order our `migration-check.yml` uses, against the same Postgres major (17). The persistent `staging` git branch will get its own persistent branch DB. Current status is in §10. Until Branching is live, schema changes still flow through `supabase db query --linked` and the migration-check workflow is the only automated apply.

### 8.5 Local verification before commit

Every CI gate runs identically on a laptop. Reproduce a failure locally before pushing:

```bash
# Seam guards
python3 tools/enforce_data_access_seams.py
python3 tools/check_web_player_drift.py
bash scripts/ci/check-no-direct-db-access.sh

# Migration sanity (only when you've touched supabase/migrations/**)
bash scripts/ci/check-migration-column-preservation.sh --all

# Docs (only when you've touched a Markdown file with a TOC)
python3 tools/verify-toc.py docs/CI.md

# Flutter
( cd app && flutter pub get && flutter analyze && flutter test )

# Web portal
( cd web-portal && npm run lint && npm run typecheck && npm run build )

# Web player syntax
for f in web-player/*.js; do node --check "$f"; done
```

These all run in CI too — running locally just saves a round-trip.

### 8.6 Adding a new check

When a memory note crystallises a rule that lint or typecheck can't catch, lift it into CI:

1. **Pick a language.** Python for richer rules (line-anchored allowlists, AST-style work). Bash for "grep this pattern outside these files" lightweight gates. If the rule is important enough, write both — the Python is canonical, the bash is a fast pre-commit.
2. **Drop the script** under `tools/` (Python) or `scripts/ci/` (bash). Header comment names the memory note that motivates the rule. For bash: `#!/usr/bin/env bash`, `set -euo pipefail`, `chmod +x`, `bash -n` clean, prints `file:line:` context on failure.
3. **Wire it into a workflow.** Append a step to the relevant job in `.github/workflows/ci.yml` (named `Custom: <rule>` for bash custom-rules), or create a dedicated workflow if the trigger differs (paths filter, base-branch filter).
4. **Initialise the exceptions file** (if the rule needs one) with the `TODO: Pare down over time. Goal: empty file.` header and any existing violations the first run surfaces. Commit the script and the exceptions file in the same PR.
5. **Document it here** — append a script entry to §8.3 and a workflow entry to §8.2.
6. **Update `scripts/ci/README.md`** so a fresh reader of just that directory understands the new rule.

### 8.7 Grandfather mechanism

When a rule lands, the codebase may already have violations. Failing CI on day one would force a giant unfocused refactor PR. Instead we capture each existing violation in the rule's exceptions file with a comment explaining the carve-out, then fail only on **new** violations. The exceptions file becomes the punch list to pare down over time.

Two exceptions files exist today, both empty:

- `tools/data_access_seam_exceptions.json` — line-anchored exceptions for the Python checker. Match key is `rule|path|line|content`. JSON, with `last_updated` and `allowed_violations` fields.
- `scripts/ci/db-access-exceptions.txt` — file-anchored exceptions for the bash checker. One repo-relative path per line; `#` starts a comment.

Hard rules for the exceptions files:

1. **TODO header at the top: "Pare down over time. Goal: empty file."** Both files have it. Don't remove it.
2. **Every entry has a comment justifying it.** Future Claude shouldn't need to dig through git history to know why a file was carved out.
3. **Delete the entry in the same PR that fixes the underlying call.** A regression caught by the rule reactivates the entry, but a stale entry silently weakens the rule.
4. **CI surfaces stale entries.** The Python checker prints `Stale allowlist entries detected (safe to remove)` for entries whose pattern no longer matches any real code. Clean those up when you see them.

Adding to an allowlist is **tech debt, not a feature.** Goal is always back to empty.

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
