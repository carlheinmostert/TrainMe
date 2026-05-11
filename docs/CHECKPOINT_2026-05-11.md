# Checkpoint — 2026-05-11 — CI/CD release-train cutover

**The day we replaced "Claude pastes SQL into the dashboard" + "every push deploys to prod" with a real three-tier release pipeline.** Twelve PRs to main, eight new memory rules, Supabase Branching live on the prod project, persistent staging environment wired end-to-end, and the meta-validation that the new auto-tag workflow tagged its own merge as `v2026-05-11.1`.

The driver was a single recurring complaint: every schema migration meant Carl pasting SQL into the Supabase dashboard while Claude watched, and every web-portal merge to `main` shipped straight to prod with no preview environment for Carl (or a beta client) to QA against. The April-23 "Projects" feature spec was lost in a worktree cleanup — a docs-only loss, but it crystallised that the whole pipeline was held together by convention. Today we replaced convention with workflows + tags + branches.

## Table of Contents

- [Status](#status)
- [The release-train — what we built and why](#the-release-train--what-we-built-and-why)
- [PR sequence](#pr-sequence)
- [Workflow file map](#workflow-file-map)
- [How a change actually moves through the pipeline now](#how-a-change-actually-moves-through-the-pipeline-now)
- [Infrastructure changes outside the PR stream](#infrastructure-changes-outside-the-pr-stream)
- [New conventions](#new-conventions)
- [Where things live now — file map](#where-things-live-now--file-map)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons learned](#lessons-learned)
- [Rollback paths](#rollback-paths)
- [Fresh-session handoff](#fresh-session-handoff)

## Status

- **Where main is:** [`a9da6ce`](https://github.com/carlheinmostert/TrainMe/commit/a9da6ce) — Merge PR [#302](https://github.com/carlheinmostert/TrainMe/pull/302). Auto-tagged `v2026-05-11.1` by the new `release-tag.yml` workflow.
- **Where Carl's iPhone is:** still on the build from 2026-05-04 (PR #223). No mobile install today — pipeline-and-infra-only day.
- **Open PRs:** two stale PRs (`#287` deep code review docs, `#288` Studio editor sheet refactor, both from 2026-05-06) still target `main`. Per the new flow they need `gh pr edit <num> --base staging` + branch refresh. Carl plans to merge tomorrow.
- **Blocked on Carl** (unchanged from 2026-05-04 — none of this is in our hands):
  - Hostinger 301 redirects: `homefit.studio/privacy|terms` → `manage.homefit.studio/...`
  - `support@homefit.studio` mailbox setup at Hostinger
  - ZA lawyer red-pen on `web-portal/src/app/privacy/page.tsx` + `terms/page.tsx`
  - PayFast production merchant account approval

## The release-train — what we built and why

Three-tier model. Every code change moves left to right:

```
feature branch (per-PR Supabase + Vercel preview)
        │
        ▼ merge
   staging   (persistent — staging.* DNS, staging Supabase branch)
        │
        ▼ explicit promotion by Carl
     main    (prod — manage.homefit.studio + session.homefit.studio + prod Supabase)
```

Each tier carries its own ephemeral DB, env vars, and deploy URL.

### The four moving pieces

1. **Supabase Branching** — per-PR DB previews + a persistent `staging` Supabase branch. Migrations live as timestamp-named files under `supabase/migrations/`. Every PR that touches `supabase/migrations/` gets a fresh DB clone of the parent branch, runs the new migration in CI, and reports green/red on the PR. Merging to `staging` applies on the staging Supabase branch. Merging staging → main applies on the prod project.
2. **Vercel preview deployments** — already existed for `homefit-web-portal` + `homefit-web-player` Vercel projects, but Preview Deployment Protection was on (login wall). Disabled both today so testers can hit preview URLs unauthenticated.
3. **Vercel-Supabase integration** — installed on both Vercel projects across Production / Preview / Development scopes. Vercel deploys now auto-pick up `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` from the linked Supabase branch instead of being hard-coded to prod. This is the load-bearing piece — without it, every PR preview would still talk to prod data.
4. **GitHub Actions automation** — five workflows under `.github/workflows/` + two custom shell scripts under `scripts/ci/`. They enforce branch naming, migration-column preservation, no-direct-DB-access, web-player drift, plus the auto-tag + per-branch-vault + release-notes jobs.

### The Flutter side

Flutter mobile reads `ENV` at compile time (`prod` / `staging` / `branch`) via `--dart-define=ENV=...`. `install-sim.sh` and `install-device.sh` take an `--env` flag and pass it through; `build-testflight.sh` (new) always hardcodes `ENV=prod`. So a tester on a staging build will only see the staging Supabase branch's data — no accidental cross-talk with prod plans.

### What's NOT shipped today

- The pipeline runs. It doesn't yet **gate** anything — `staging` doesn't require a green CI run before promotion. Carl explicitly wanted to land it and watch it for a session or two before tightening enforcement.
- The CI-side migration smoke (`supabase db reset` against a temp branch and re-running every migration from baseline) is wired but not blocking PRs yet.

## PR sequence

Twelve PRs, in chronological order. Plus the three docs commits (4229c2e, 5954847/68eb0d6/9fb820b/9af0186) that went direct to `main` per the specs-direct-to-main rule.

| # | SHA / PR | Title | Why |
|---|---|---|---|
| 1 | [`4229c2e`](https://github.com/carlheinmostert/TrainMe/commit/4229c2e) | `docs: restore BACKLOG_PROJECTS.md (Class Sales / revenue-share spec)` | Reconstructed the 2026-04-23 Projects feature spec lost in a worktree cleanup. 535 lines, direct to main. The loss is what triggered the specs-direct-to-main rule. |
| 2 | [`29277ac`](https://github.com/carlheinmostert/TrainMe/commit/29277ac) | `supabase: baseline migration for Branching adoption` | `supabase/migrations/20260511065443_baseline.sql` (4,985 lines). Sourced live from prod via introspection (`pg_get_functiondef`, `pg_dump --schema-only`). 20 tables, 65 functions, 36 RLS policies, 3 triggers. This is what Supabase Branching diffs every per-PR DB against. |
| 3 | [`5954847`](https://github.com/carlheinmostert/TrainMe/commit/5954847) | `docs: add STAGING.md release-workflow runbook` | First version of the release-pipeline doc. |
| 4 | [`68eb0d6`](https://github.com/carlheinmostert/TrainMe/commit/68eb0d6) | `docs: add table of contents to STAGING.md` | Retrofit per the new "every new doc starts with a TOC" rule (still being learned the hard way — wrote the doc, then added the rule, then retrofitted). |
| 5 | [`9fb820b`](https://github.com/carlheinmostert/TrainMe/commit/9fb820b) | `docs: rename STAGING.md → CI.md` | Corrected the framing — the doc is a CI/CD strategy doc; staging is one phase of it. |
| 6 | [`9af0186`](https://github.com/carlheinmostert/TrainMe/commit/9af0186) | `docs: update CLAUDE.md pointer to docs/CI.md` | Pointer follow-up after the rename. |
| 7 | [#291](https://github.com/carlheinmostert/TrainMe/pull/291) + [#292](https://github.com/carlheinmostert/TrainMe/pull/292) | Full CI/CD automation | Five workflows: extended `ci.yml`, new `migration-check.yml`, `branch-name-check.yml`, `release-notes.yml`, reused `web-player-drift-guard.yml`. Two custom scripts: `scripts/ci/check-no-direct-db-access.sh`, `scripts/ci/check-migration-column-preservation.sh`. Pre-existing `tools/enforce_data_access_seams.py` discovered + preserved. |
| 8 | [#293](https://github.com/carlheinmostert/TrainMe/pull/293) | `feat(web-player): env-config via window.HOMEFIT_CONFIG` | Web player reads Supabase config from `window.HOMEFIT_CONFIG` injected at deploy time via `build.sh`. Service worker bumped to `v76-env-config`. Was hard-coded to prod URL + anon key in source. Now staging deploys talk to the staging Supabase branch. |
| 9 | [#295](https://github.com/carlheinmostert/TrainMe/pull/295) + [#296](https://github.com/carlheinmostert/TrainMe/pull/296) | `fix: gitignore + workflow path-filter zero-base` | Web-player `.gitignore` improvements + a real CI bug — push-event with zero-base (initial push of a branch) wasn't gated correctly in the iOS build job, wasting macOS minutes. |
| 10 | [#297](https://github.com/carlheinmostert/TrainMe/pull/297) | `ci: populate vault.secrets on Supabase preview branch DBs` | New `supabase-branch-vault.yml` workflow. Populates `supabase_url` + `supabase_jwt_secret` in `vault.secrets` on per-PR branch DBs (the `sign_storage_url` helper needs these to return non-null). Idempotent, soft-fail — if it can't find the branch, it logs + exits 0 rather than failing the PR. |
| 11 | [#298](https://github.com/carlheinmostert/TrainMe/pull/298) | `feat(flutter): ENV flag + branch-aware install scripts` | `app/lib/config.dart` reads `ENV` at compile time. `install-sim.sh` + `install-device.sh` gain `--env prod/staging/branch`. New `build-testflight.sh` hardcodes `ENV=prod` so a TestFlight upload can never accidentally point at staging. |
| 12 | [#299](https://github.com/carlheinmostert/TrainMe/pull/299) | `ci(release-tagging): auto-tag main merges + bump-version.sh tags` | New `release-tag.yml` workflow auto-tags every merge to `main` as `v{YYYY-MM-DD}.{N}` (N = nth release that UTC date). Direct pushes to main (docs-only) deliberately skip tagging. `bump-version.sh` extended to git-tag mobile uploads as `mobile-v{version}+{build}` (backwards-compat via `--no-tag` flag). |
| 13 | [#300](https://github.com/carlheinmostert/TrainMe/pull/300) | `feat(web): render git SHA + branch on both web surfaces` | Low-opacity build chips in the footer of `manage.homefit.studio` + `session.homefit.studio`. Branch + short SHA. Mirrors the mobile `GIT_SHA` footer pattern. Means a glance at any preview URL tells you which branch is live. |
| 14 | [#301](https://github.com/carlheinmostert/TrainMe/pull/301) | `chore: archive 72 legacy schema_*.sql patch files` | All 72 `supabase/schema_*.sql` files moved to `supabase/archive/`. README added documenting the archive — historical reference only; do not apply. Baseline migration superseded them. |
| 15 | [#302](https://github.com/carlheinmostert/TrainMe/pull/302) | `chore: cutover bundle — staging → main` | Final bundle. Bundles #297–#301. Merge to main triggered `release-tag.yml` — which auto-created `v2026-05-11.1`. **Meta-validation: the new workflow tagged its own enablement merge.** |

PR companion docs:

- `CLAUDE.md` gained a "Versioning" section explaining `v{date}.{N}` + `mobile-v*` tag schemes.
- `docs/CI.md` §10 cutover checklist — all 13 items flipped to ✅.

## Workflow file map

Each `.github/workflows/*.yml` file maps to one concern. The complete picture as of end-of-session:

| File | Trigger | What it does | Blocking? |
|---|---|---|---|
| `ci.yml` | PR + push | iOS build smoke (release config, no signing); web-portal `npm run build`; web-player static-bundle drift guard (re-uses `web-player-drift-guard.yml`). Path-filtered so a docs-only PR skips iOS. | Yes (existing) |
| `migration-check.yml` | PR with changes under `supabase/migrations/` | Runs `scripts/ci/check-migration-column-preservation.sh` — for every `CREATE OR REPLACE FUNCTION` in the diff, fetches the live function definition from prod, diffs the `RETURNS TABLE` column lists, fails if any column is dropped silently. | No (advisory for now) |
| `branch-name-check.yml` | PR opened / synchronize | Asserts branch name matches `^(feat|fix|chore|docs)/.+`. `claude/*` branches grandfathered. | No (advisory for now) |
| `release-notes.yml` | PR ready-for-review | Generates a draft release-notes block from commit subjects since the merge base; posts as a sticky PR comment. Pipefail-safe `grep` (the bug that 001ba88 introduced and `fa73be1` fixed). | N/A (comment-only) |
| `release-tag.yml` | Push to `main` from a merge commit | Computes `v{YYYY-MM-DD}.{N}` where `N` is the nth release-train tag that UTC date; creates + pushes the annotated tag. Skips direct pushes (i.e., docs-only commits like this checkpoint commit itself) — those have no merge SHA in the parent chain. | N/A (post-merge automation) |
| `web-player-drift-guard.yml` | Reusable workflow | Asserts `web-player/build.sh` and the rendered `web-player/index.html` are in sync. Catches the case where `build.sh` injects HTML but the committed `index.html` was edited by hand. Already existed pre-today; called from `ci.yml`. | Yes |
| `supabase-branch-vault.yml` | PR open / reopen / synchronize on `supabase/migrations/**` | Polls Supabase Management API until the branch DB is ready (positive-confirmation exit, not iteration-count exit — see Lessons Learned). Idempotently upserts `supabase_url` + `supabase_jwt_secret` into the branch DB's `vault.secrets`. Soft-fails (logs + exits 0) if the branch doesn't materialise — doesn't block the PR. | No (soft-fail) |

Two custom shell scripts plug into the workflows:

- `scripts/ci/check-no-direct-db-access.sh` — greps for forbidden direct Supabase client calls outside the per-surface access layer (`api_client.dart`, `api.ts`, `api.js`). Uses `scripts/ci/db-access-exceptions.txt` for allowlisted paths.
- `scripts/ci/check-migration-column-preservation.sh` — the live-vs-PR `RETURNS TABLE` diff. Calls `pg_get_functiondef` via `psql` over the migration-check DB.

One pre-existing Python tool was discovered + preserved:

- `tools/enforce_data_access_seams.py` — older static-analysis check that the `api_client.dart` / `api.ts` / `api.js` files only expose enumerated RPC wrappers. Has an exception list at `tools/data_access_seam_exceptions.json`. Mention here because future-Claude may otherwise add a `scripts/ci/check-data-access-seams.sh` and duplicate it.

## How a change actually moves through the pipeline now

End-to-end walkthrough for the three change-shapes that come up most.

### A new schema migration (the case Branching was built for)

1. Carl asks for a feature. Claude writes the migration as `supabase/migrations/YYYYMMDDHHMMSS_<name>.sql`.
2. Branch the work as `feat/<short-name>`. Open a PR against `staging`.
3. Supabase Branching auto-creates a per-PR DB clone of the parent branch (initially `staging`). Migrations run; the PR comment from the Supabase GitHub App shows green/red.
4. `supabase-branch-vault.yml` populates the vault secrets on the new branch DB so `sign_storage_url` works.
5. The Vercel-Supabase integration injects the per-PR branch DB's URL + anon key into both web previews. The preview URLs (auto-generated `*.vercel.app` hostnames) now talk to the per-PR DB, not prod.
6. Tester hits the preview URL, exercises the new schema. If broken, push fixes to the same branch; preview + DB redeploy.
7. Merge to `staging`. The same migration applies on the persistent staging branch (`vadjvkmldtoeyspyoqbx`); `staging.session.homefit.studio` + `staging.manage.homefit.studio` now reflect it.
8. Carl explicitly promotes staging → main when ready. The migration applies on prod. `release-tag.yml` auto-tags the merge as `v{date}.{N}`.

### A web-only tweak (no schema change)

1. Branch as `fix/<short-name>` off `staging`. PR against `staging`.
2. Vercel auto-deploys a preview. No Supabase Branching DB is created (no migration touched).
3. Preview talks to the staging Supabase branch's data (via Vercel-Supabase integration's Preview-scope env vars).
4. Tester hits the preview URL.
5. Merge to `staging` → staging Vercel deploy. Promote staging → main → prod Vercel deploy + auto-tag.

### A docs-only change (this checkpoint commit, for instance)

1. Use an ephemeral worktree on `main`. Write the doc. Verify TOC with `tools/verify-toc.py`. Commit + push.
2. `release-tag.yml` skips (no merge SHA in parent). No DB or web work happens.
3. After commit, pull main back into Carl's current worktree (`feedback_pull_main_after_direct_commit.md`) so the file appears in his Files panel.

## Infrastructure changes outside the PR stream

These don't sit in git but are load-bearing for the pipeline. Future-Claude should know these exist before "fixing" anything related to staging or per-PR previews.

### Supabase

- **Branching enabled** on the prod project (`yrwcofhovrcydootivjx`). The "Branches" entry in the Supabase sidebar is now live.
- **Persistent staging branch created** (`vadjvkmldtoeyspyoqbx`). Wired to the `staging` git branch so every staging merge re-applies migrations there. This branch is long-lived — not torn down between PRs.
- **GitHub App installed** on the repo. This is what lets Supabase Branching subscribe to PR events.
- **Migration history aligned** on both prod main and staging branch DBs via `supabase migration repair`. A phantom `20260511092902` entry was removed from the history table; the actual baseline `20260511065443` was registered. Without this, the next migration would have failed with "remote not in sync".
- **Vault secrets** (`supabase_url`, `supabase_jwt_secret`) populated on the staging Supabase branch. Same values as prod but pointing at the staging-branch URL. The `sign_storage_url` helper needs both — without them, the helper returns null and three-treatment playback breaks silently on staging.
- **Standalone `homefit.studio-staging` Supabase project (`txxprpxlumstzxjnbtuo`) deleted.** That project was a one-time schema-flatten rehearsal used to dry-run the baseline migration; the persistent staging branch on prod supersedes it. Deleted to remove the temptation to drift two staging DBs.
- **Repo secret `SUPABASE_ACCESS_TOKEN`** added by Carl (for the per-branch-vault workflow's CLI calls).

### Vercel

- **Vercel-Supabase integration installed + configured** on both Vercel projects (`homefit-web-portal`, `homefit-web-player`). Production / Preview / Development scopes all sync env vars with `NEXT_PUBLIC_` prefix. Every per-PR preview deploy now has the right Supabase URL/key injected automatically.
- **Preview Deployment Protection disabled** on both Vercel projects. Preview URLs are now publicly accessible for testing — no Vercel login wall.

### DNS (Hostinger)

- **`staging.manage.homefit.studio` + `staging.session.homefit.studio`** CNAMEs added pointing at `cname.vercel-dns.com`. Both subdomains assigned to the staging git branch via the Vercel API. Currently serving HTTP 200.

That's the actual user-visible staging environment. A Carl-side beta client can be pointed at `staging.session.homefit.studio` and exercise the workflow against a non-prod database.

## New conventions

Eight new memory entries under `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/memory/` codify the day's lessons:

1. **`feedback_specs_direct_to_main.md`** — Specs / design docs / checkpoints / runbooks go directly to `main`. No PR, no branch. A spec sitting in a worktree is one cleanup away from gone. Driven by the 2026-04-23 Projects spec loss.
2. **`feedback_use_apis_not_dashboards.md`** — Ask permission then execute via CLI / Management API. Don't make Carl click through dashboards. Applies to Supabase auth config / vault / storage / RLS and Vercel env vars / domains / project linking. Carl explicitly asked.
3. **`project_staging_environment.md`** — Vocabulary lock: the pre-prod environment is "staging", not "dev". Long-term architecture: Supabase Branching on the prod project (per-PR DB previews + persistent staging branch). The standalone `homefit.studio-staging` project was a one-time rehearsal, now decommissioned.
4. **`feedback_branch_naming_discipline.md`** — Ask Carl for branch name at task start. `feat/` / `fix/` / `chore/` prefixes. Target `staging` not `main` for code PRs. Carl explicitly promotes staging → main. Docs still skip branches (direct to main).
5. **`feedback_markdown_toc.md`** — Every new doc under `docs/` or at repo root starts with a `## Table of Contents` section. Anchor-derivation rules captured (GitHub's slug algorithm). Verification tool: `tools/verify-toc.py`. Applies to substantial restructures too; short memory files exempt.
6. **`feedback_pull_main_after_direct_commit.md`** — Companion to specs-direct-to-main. After committing direct-to-main via ephemeral worktree, `git pull --ff-only origin main` in Carl's current worktree so the file appears in his Files panel. Fallback: surgical `git checkout origin/main -- <file>` if branches diverged.
7. **`gotcha_test_scripts_index_cascade.md`** — Updated (existed before today, gained a new incident). Always `grep -c "<<<<<<<"` on the file before push (must be 0). Git accepts commits based on index state, NOT file content — so a half-resolved conflict can ride into main. Two real incidents in two weeks: PR #202 → #208 (test-scripts/index.html) and 001ba88 (docs/CI.md).
8. **`feedback_agent_worktree_isolation.md`** — Already existed, referenced again today. When spawning sub-agents with `isolation: worktree`, brief them with repo-relative paths, never `/Users/chm/dev/TrainMe/…`. A PreToolUse hook enforces this; briefs should still be clean at authorship time.

The new version-tag schemes are documented in CLAUDE.md's "Versioning" section:

- **Web:** every merge to `main` → `v{YYYY-MM-DD}.{N}` (N = nth release that UTC date). Direct pushes to main (docs-only) skip tagging.
- **Mobile:** every `bump-version.sh` run → `mobile-v{version}+{build}` (e.g. `mobile-v1.0.0+4`). `--no-tag` opts out for legacy use.
- **DB:** the migration filename timestamp is the version. No separate version number.

## Where things live now — file map

For the fresh-session Claude who needs to know where today's bits live without grepping the whole repo:

**Workflows (`.github/workflows/`):**
- `ci.yml` — main CI orchestrator
- `migration-check.yml` — schema migration column-preservation check
- `branch-name-check.yml` — branch naming enforcement
- `release-notes.yml` — PR release-notes comment
- `release-tag.yml` — auto-tag main merges
- `web-player-drift-guard.yml` — web-player build vs index drift guard
- `supabase-branch-vault.yml` — per-PR branch vault seed

**CI scripts (`scripts/ci/`):**
- `check-no-direct-db-access.sh` — direct-Supabase-client greppy check
- `check-migration-column-preservation.sh` — live-DB vs PR `RETURNS TABLE` diff
- `db-access-exceptions.txt` — allowlist for above

**Pre-existing tools (`tools/`):**
- `enforce_data_access_seams.py` — older Python seam-checker
- `data_access_seam_exceptions.json` — its allowlist
- `verify-toc.py` — TOC anchor checker (introduced 2026-05-11)

**Schema (`supabase/`):**
- `migrations/20260511065443_baseline.sql` — canonical baseline (4,985 lines)
- `migrations/README.md` — migration-naming convention + how Branching uses them
- `archive/` — 72 legacy `schema_*.sql` patch files; historical only
- `archive/README.md` — explains the archive
- `schema.sql` — older fresh-install schema (kept for reference; baseline superseded)

**Mobile env wiring:**
- `app/lib/config.dart` — reads `ENV` from `--dart-define`
- `install-sim.sh` — `--env prod/staging/branch` flag
- `install-device.sh` — same flag
- `build-testflight.sh` — new, hardcodes `ENV=prod`
- `bump-version.sh` — now creates `mobile-v{version}+{build}` git tag (opt out with `--no-tag`)

**Build info on web:**
- `web-portal/src/components/BuildInfo.tsx` — git SHA + branch chip in portal footer
- `web-player/build.sh` — strict-fail policy + writes `window.HOMEFIT_CONFIG` into `index.html` at build
- `web-player/.gitignore` — `.vercel/` ignored

**Docs:**
- `docs/CI.md` — the canonical pipeline doc (§10 cutover checklist now all ✅)
- `docs/CHECKPOINT_2026-05-11.md` — this file
- `docs/BACKLOG_PROJECTS.md` — restored Class Sales spec (commit `4229c2e`)

## Open follow-ups for next session

External / Carl-side blockers for App Store launch (unchanged from 2026-05-04):

- Hostinger 301 redirects: `homefit.studio/privacy|terms` → `manage.homefit.studio/...`
- `support@homefit.studio` mailbox setup at Hostinger
- ZA lawyer red-pen on `web-portal/src/app/privacy/page.tsx` + `terms/page.tsx`
- PayFast production merchant account approval

Pipeline-side follow-ups:

- **Two stale PRs** (`#287` deep code review docs, `#288` Studio editor sheet refactor, both from 2026-05-06) still target `main`. Per the new flow they need `gh pr edit <num> --base staging` + a branch refresh. Carl plans to merge them tomorrow.
- **Tighten CI enforcement** once the pipeline has run for a session or two: make `migration-check.yml` blocking, make `branch-name-check.yml` blocking on PRs.
- **Document the per-PR Supabase preview tear-down**. Supabase Branching auto-purges PR DBs after merge or close, but the timing isn't documented in CI.md yet.
- **Staging Supabase data refresh policy**. Right now the staging branch is a copy of prod-as-of-2026-05-11. There's no scheduled refresh; over time staging will drift from prod. Worth deciding: refresh-weekly cron, refresh-on-demand button, or accept-drift-as-feature.
- **Per-PR mobile builds.** Not in scope for today. A `--env=branch` Flutter build talking at a per-PR Supabase branch DB would need the URL/key injected at compile time. Possible follow-up; today's scope was web-only per-PR previews.
- **Stripe / PayFast in staging.** Staging currently shares prod's PayFast sandbox creds. Not a real production hazard (sandbox is sandbox), but worth a thought before any production cutover.

## Lessons learned

Three traps surfaced today. All three are now memory entries; flagging here for fresh-session continuity.

### Conflict-marker leak into main (commit [`001ba88`](https://github.com/carlheinmostert/TrainMe/commit/001ba88))

One of the staging→main merges left literal `<<<<<<< HEAD` markers in `docs/CI.md`. Git accepted the commit because the *index* was clean — the regex resolver had marked the path as resolved without verifying the *file content* was free of conflict markers. The CI.md cutover checklist + docs/CI.md §10 both rendered with raw markers visible on GitHub until the follow-up cleanup commit.

Same trap that hit `docs/test-scripts/index.html` in PR #202 → fixed by #208 on 2026-05-03. Two incidents, same root cause. Memory entry `gotcha_test_scripts_index_cascade.md` now reads more generally — *any* file touched by a multi-region cascade conflict needs a `grep -c "<<<<<<<" <file>` (must be 0) before push.

### The polling-logic bug in the per-branch-vault workflow

The first version of `supabase-branch-vault.yml` polled the Supabase API for branch readiness with a fixed retry count. The polling loop's exit condition was wrong (off-by-one) — it would exit successfully on the iteration after the branch came online, regardless of whether the vault upsert had actually succeeded. Caught during PR #297 review; rewrote the loop to fail closed (must explicitly see a successful upsert response before exit).

Take-away: any "poll until ready then do thing" loop needs a positive-confirmation exit, not a side-effect exit.

### Workflow path-filter zero-base trap

PR #295 / #296 was a real CI bug, not a config nit. When a branch is pushed for the first time, GitHub's `paths` filter on a `push` event compares against a zero-base SHA (`0000000000000000000000000000000000000000`). The `dorny/paths-filter` action treats that as "everything changed", running every job — including the iOS / macOS build job, which burns 8–10× the minutes of the Linux jobs.

Fix: explicit `if: github.event.before != '0000000000000000000000000000000000000000'` gate on the expensive jobs for `push` events. Pull-request events are unaffected (they always have a real base SHA). Caught when an unexpected `~12 minute` macOS-runner bill showed up.

## Rollback paths

If the pipeline goes sideways on a future session, here are the levers in order of severity (least → most destructive):

**Just my PR is wedged.** Close the PR. Supabase Branching auto-cleans up the branch DB. Vercel preview deploy goes stale but is harmless. Open a fresh PR with a clean branch name (matches `^(feat|fix|chore|docs)/`).

**Staging is in a bad state.** The staging Supabase branch (`vadjvkmldtoeyspyoqbx`) lives at the same project; its migration history can be `supabase migration repair`-ed without touching prod. The staging git branch can be force-reset to match main if migrations have piled up on it — but coordinate with Carl first; he wants `staging` to remain a superset of `main`, not a peer.

**Prod migration applied an oops.** Two options:
1. Forward fix: write a new migration that reverses the damage. Apply via the normal pipeline (or, if truly urgent, `supabase db query --linked --file ...` direct against prod as a hot-fix — then back-port the same SQL into a proper migration file in the next PR so the chain stays consistent).
2. `supabase migration repair --status reverted <timestamp>` to mark a specific migration as not-applied, then drop the schema changes manually. Last resort.

**Need to disable the whole automation stack.** All workflows are individually toggleable in `.github/workflows/`. The pipeline is observability-only for now (advisory checks, no PR-blocking) so disabling any single workflow is low-risk. The two destructive levers are:
- Delete the persistent staging Supabase branch (Branching menu in Supabase dashboard). All staging data is lost; the staging git branch becomes pointless until a fresh branch is provisioned + vault re-populated.
- Disable Supabase Branching entirely on the prod project. Reverts to "Claude pastes SQL into the dashboard" workflow. Don't do this lightly — it's a manual provisioning unwind.

**Need to undo a `v{date}.{N}` tag.** `git tag -d v2026-05-11.1 && git push origin :refs/tags/v2026-05-11.1`. The tag carries no functional weight (no deploy is gated on it); it's a bookmark. Re-running `release-tag.yml` won't recreate it because the workflow only fires on push events, not on manual dispatch (today).

## Fresh-session handoff

Read this file first, then CLAUDE.md (the "Current Phase" section there now points to this checkpoint). The two prior checkpoints (`docs/CHECKPOINT_2026-05-04.md` for the polish wave + `docs/CI.md` for the pipeline detail) remain authoritative for their domain.

Three quick-reference pointers for the next session:

- **Want to add a schema migration?** Create `supabase/migrations/{YYYYMMDDHHMMSS}_<name>.sql`. PR it against `staging`. Per-PR Supabase Branching applies it to a fresh DB clone in CI; if green, merging applies it on the staging branch. Carl then promotes staging → main, and the same migration applies on prod.
- **Want to QA on staging?** Hit `staging.session.homefit.studio` (or `staging.manage.homefit.studio`). It talks to the staging Supabase branch DB. The build-info chip in the footer confirms which branch is live.
- **Want to verify a checkpoint's TOC?** `python3 tools/verify-toc.py docs/CHECKPOINT_2026-05-11.md`. Exits 0 if every TOC link resolves to a real heading anchor.

The `homefit.studio` brand, Reader-App compliance, the v6 line-drawing tuning lock, and the v8 hand-pose dilation re-enable are all unchanged from 2026-05-04. Bundle ID is still `studio.homefit.app`. App version is still `1.0.0+1` (TestFlight v1 from 2026-05-05).
