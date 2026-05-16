# `scripts/ci/` — custom-rule checks

Bash scripts invoked by `.github/workflows/ci.yml` (job `custom-rules`) and
`migration-check.yml`. Each script enforces a codebase rule that lives in the
memory layer (`feedback_*.md`) and isn't covered by lint or typecheck.

These scripts are designed to be:

- **Fast** — sub-second for a clean run, so they can also serve as
  pre-commit hooks if you want.
- **Local-first** — every script runs identically on your laptop and in CI.
  No GitHub-specific env vars, no `gh` calls.
- **Honest about scope** — when a check can't be fully automated (the
  migration column-preservation case), it nudges rather than fakes a hard
  fail.

## Files

| File | Purpose | Hard / soft |
|------|---------|-------------|
| `check-no-direct-db-access.sh` | Forbids `.from(` / `.rpc(` / `.storage` / `/rest/v1/` / `Supabase.instance.client` outside the per-surface access layer. | Hard fail |
| `check-migration-column-preservation.sh` | Surfaces every `CREATE OR REPLACE FUNCTION ... RETURNS TABLE` in changed migration files, asks the reviewer to verify the prior column list is preserved. | Soft (warnings only) |
| `check-hero-resolver.sh` | Forbids `object-fit: cover` on `.lobby-hero-media` (the `<img>` selector), `heroCropOffset` reads outside the resolver / model / editor allow-list, and static `_thumb*.jpg` `<img>` tags in lobby code. Scans `web-player/` and `app/assets/web-player/` (R-10 mirror). See `docs/HERO_RESOLVER.md`. | Hard fail |
| `db-access-exceptions.txt` | Grandfathered carve-outs for the direct-DB-access check. One repo-relative path per line. Goal: empty file. | Data |

## Running locally

From the repo root:

```bash
# Full sweep
scripts/ci/check-no-direct-db-access.sh

# Migration check — defaults to diff vs origin/main
scripts/ci/check-migration-column-preservation.sh

# Migration check — scan every migration file
scripts/ci/check-migration-column-preservation.sh --all

# Hero resolver single-source-of-truth
scripts/ci/check-hero-resolver.sh
```

Both scripts use `set -euo pipefail`. They print `OK: ...` on success or
itemise violations with `file:line:` context on failure.

## How `check-no-direct-db-access.sh` decides what's allowed

1. The path is in the explicit allowlist baked into the script header:
   - `app/lib/services/api_client.dart`
   - `web-portal/src/lib/supabase/api.ts`
   - `web-portal/src/lib/supabase/database.types.ts`
   - `web-player/api.js`
   - `web-player/middleware.js` (bot-unfurl carve-out)
2. The path falls under a whitelisted prefix:
   - `web-portal/src/lib/supabase/` (the whole access layer)
   - `supabase/functions/` (Edge Functions run with service role)
   - `web-player/html2canvas.min.js` (vendored library)
3. The path appears (line-exact) in `db-access-exceptions.txt`.

If none of those match and the file contains a forbidden pattern, CI fails
with `ERROR: N new direct-DB-access violation(s) found.`

## Relationship to `tools/enforce_data_access_seams.py`

The Python checker in `tools/` is the **richer, line-anchored** variant: it
records each violation as `rule|path|line|content` and stores grandfather
exceptions in `tools/data_access_seam_exceptions.json` keyed by that exact
string. Use the Python checker as the authoritative gate in CI for nuanced
allowlisting; use this bash script as the lightweight version (fast pre-
commit, blast-radius safety net).

Both pass on the current `main` (`tools/data_access_seam_exceptions.json` is
empty; `scripts/ci/db-access-exceptions.txt` is empty). If they ever
disagree, treat the Python checker as canonical and update the bash glob
allow-rules to match.

## How to add a new rule

1. Drop the script in this directory. Make it `#!/usr/bin/env bash`,
   `set -euo pipefail`, chmod +x, with a header comment explaining what it
   enforces and pointing at the memory note that motivates the rule.
2. Wire it into `.github/workflows/ci.yml` under the `custom-rules` job
   (one step per script, names start with `Custom: …`).
3. Update the table in this README.
4. Update `docs/CI.md` §10 ("Automation") describing what the rule is and
   where its exceptions live.

## How to add a new grandfathered exception

1. Run `scripts/ci/check-no-direct-db-access.sh` and locate the offending
   file path.
2. Add the path to `db-access-exceptions.txt` with a `#` comment line
   directly above it explaining why this is a stopgap and what the fix
   would look like.
3. Open a TODO item or backlog note tracking the eventual fix.
4. Re-run the script; it should now pass.

When the underlying call is finally routed through the access layer,
delete the path from the exceptions file in the same PR.
