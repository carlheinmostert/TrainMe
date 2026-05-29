---
name: homefit:promote-staging-to-main
description: Draft the release-promotion PR from staging to main — diff branches, generate release notes from PR titles since the last v2026-MM-DD.N tag, open the PR, run pre-merge sanity checks. STOPS before merge; Carl explicitly promotes. Use when Carl says "promote staging", "release to prod", "ship staging to main", "draft release PR".
---

# homefit:promote-staging-to-main

Draft the release-train promotion PR from `staging` to `main`. Encodes the three-tier release model from `docs/CI.md` and the `feedback_branch_naming_discipline` rule ("Carl explicitly promotes staging → main"). This skill STOPS before merge — Carl pushes the green button.

## Inputs

- No required inputs. The skill works against `origin/staging` and `origin/main`.
- Today's date is used for the branch name and PR title; pull from `date +%F`.

## Workflow

### 1. Fetch + verify state

```
git fetch origin main staging --tags
```

Run a tight pre-flight:

- Current working tree is clean. If not, BAIL with a message asking Carl to stash or commit first.
- `origin/staging` exists. If not, BAIL.
- `origin/staging` has commits not on `origin/main`. If empty, BAIL with "Nothing to promote — staging is already at main."

### 2. List commits that would ship

```
git log --oneline --no-merges origin/main..origin/staging
```

Capture the list. Count commits. If > 200, surface a warning ("Large release — N commits since main") and ask Carl whether to proceed.

### 3. Find the last release tag

```
git tag --list "v2026-*" --sort=-v:refname | head -1
```

Tags follow `v{YYYY-MM-DD}.{N}` per the `release-tag.yml` workflow. The first match is the most recent release. Capture its date for the gh-PR query window.

### 4. Read merged PR titles for grouping

```
gh pr list --state merged --search "merged:>=<lastTagDate>" --limit 100 --json number,title,labels,mergeCommit
```

For each commit in step 2's list, match its hash to a merged PR's mergeCommit. Build a structured list:

- PR number (`#NNN`)
- Title (one-line)
- Area (inferred from the title prefix or file paths the PR touched — see step 5)

### 5. Group by area

Bucket each PR into one of:

- **player** — `web-player/` touched
- **portal** — `web-portal/` touched
- **app** — `app/` (Flutter / iOS) touched
- **db** — `supabase/migrations/` touched
- **docs** — only `docs/` or root markdown touched
- **infra** — `.github/`, `.claude/`, hooks, CI config touched
- **other** — fallback

For each PR, peek the file paths via `gh pr view <num> --json files` if the title doesn't make it obvious. Bucket assignment is best-effort, not exact.

### 6. Generate release notes

Format:

```markdown
## Release {YYYY-MM-DD}

{commit count} PRs ship from staging to main since {lastTagDate}.

### Player
- #NNN — title
- ...

### Portal
- #NNN — title
- ...

### App
- #NNN — title
- ...

### DB
- #NNN — title
  (migration: `supabase/migrations/{timestamp}_{name}.sql`)
- ...

### Docs
- #NNN — title
- ...

### Infra
- #NNN — title
- ...

## Pre-merge sanity

- Flutter analyzer: {pass/fail}
- Vercel preview (portal): {url, status}
- Vercel preview (player): {url, status}
- Pending schema migrations on prod: {count, list or "none"}

## Merge plan

Carl merges via "Squash and merge" (NOT rebase — auto-tag workflow keys off merge commits).
After merge, `release-tag.yml` fires and lands `v{YYYY-MM-DD}.{N}`.
Verify with: `git fetch --tags && git tag --sort=-v:refname | head -1`
```

Omit empty buckets.

### 7. Create branch + push

```
git checkout -b release/{YYYY-MM-DD} origin/staging
git push -u origin release/{YYYY-MM-DD}
```

If `release/{YYYY-MM-DD}` already exists locally or remotely, append `-2`, `-3`, etc. — Carl may run promotions twice in one day.

### 8. Open PR

```
gh pr create \
  --base main \
  --head release/{YYYY-MM-DD} \
  --title "release: {YYYY-MM-DD} — N PRs ({one-line summary})" \
  --body "$(cat <<'EOF'
{release notes from step 6}
EOF
)"
```

One-line summary should pick the dominant area (e.g. "portal polish + 2 player fixes"). Keep PR title under 70 chars.

### 9. Pre-merge sanity checks (best-effort)

Run these and inline-update the PR body with results (or surface in chat):

- **Flutter analyzer**: `cd app && flutter analyze --no-pub` (if the diff touches `app/`). Don't bail on failures — surface them in the PR body so Carl can see.
- **Vercel previews**: query `vercel ls --scope carlheinmosterts-projects --json` for both `homefit-web-portal` and `homefit-web-player`. Confirm latest preview deployment on `release/{YYYY-MM-DD}` is `READY`. Link both URLs in the PR body.
- **Pending schema migrations**: compare `supabase/migrations/` against what's applied on prod. The cleanest probe is the migrations chain — check whether any timestamp-named file in the diff has not been applied on prod via Supabase Branching's per-PR DB.

These are best-effort. If a check fails to run (network, missing CLI), note it in the PR body as "skipped: {reason}" rather than blocking.

### 10. STOP. Return the PR URL.

End the reply with:

- PR URL.
- Commit count + one-line summary.
- Pre-merge sanity check results.
- A reminder: "Carl merges. Auto-tag will land `v{YYYY-MM-DD}.{N}` on merge."
- A reminder of the post-merge Vercel-spend check (per `feedback_vercel_spend_monitor`): after merge fires, capture MTD spend via `vercel ls` or the dashboard and surface it.

DO NOT merge. DO NOT enable auto-merge. Carl reviews and merges manually.

## Critical safety rules

- NEVER `gh pr merge` from this skill. Carl explicitly promotes (`feedback_branch_naming_discipline`).
- NEVER force-push the release branch — if Carl wants changes, he'll cherry-pick or amend on staging then re-run.
- NEVER include `--auto-merge` flag.
- If the diff touches `supabase/migrations/`, surface those migrations PROMINENTLY in the PR body — schema changes are irreversible and Carl needs to see them clearly.
- If the diff includes any new `CREATE OR REPLACE FUNCTION` on client-facing RPCs (`upsert_client`, `get_plan_full`, `consume_credit`, `list_practice_clients`, `replace_plan_exercises`, etc.), call them out under a "Sensitive RPCs touched" header per `feedback_sensitive_code_review_before_merge`.

## Don'ts

- Don't promote if staging has unresolved conflict markers anywhere — pre-grep `docs/test-scripts/index.html` with the same check used by `homefit:resolve-test-script-index`. If markers found, BAIL and tell Carl to resolve first.
- Don't promote if `staging` has any commits that are NOT merged-via-PR (direct pushes) — those should be specs-direct-to-main and don't belong on staging anyway. Surface them; Carl decides whether to proceed.
- Don't generate release notes from the raw commit messages — use the merged PR titles (cleaner, often rewritten at squash).
- Don't notify WhatsApp from this skill — that's for ship-to-phone, not release promotion.

## Encodes

- `feedback_branch_naming_discipline` — staging → main promotion is explicit.
- `feedback_vercel_spend_monitor` — surface MTD spend reminder after the merge fires.
- `feedback_sensitive_code_review_before_merge` — call out RPC changes prominently.
- `feedback_specs_direct_to_main` (by absence) — flag any non-PR commits on staging as anomalies.
- `docs/CI.md` — the three-tier release-train model the pipeline runs (not yet gates).
- The release-tag workflow conventions (`v{YYYY-MM-DD}.{N}`) from `.github/workflows/release-tag.yml`.
