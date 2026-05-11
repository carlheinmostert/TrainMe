#!/usr/bin/env bash
# check-migration-column-preservation.sh
# ----------------------------------------------------------------------------
# Enforces the lesson from feedback_schema_migration_column_preservation.md:
# when `CREATE OR REPLACE FUNCTION ... RETURNS TABLE (...)` is re-issued,
# every column from the prior definition must be carried forward.
# `CREATE OR REPLACE` silently drops anything missing.
#
# What this script does
# ---------------------
# Soft check: it scans the migration diff (or all migrations if invoked with
# `--all`) for `CREATE OR REPLACE FUNCTION ... RETURNS TABLE` blocks and
# prints a nudge for each, pointing the reviewer to the prior definition.
# It does NOT compare column lists automatically — that would need a real
# PL/pgSQL parser. The goal is to surface the human-review checkpoint at the
# moment it matters.
#
# Future: when CI grows a parsing helper (or `supabase db lint` covers this),
# upgrade to a hard fail.
#
# Usage
# -----
#   scripts/ci/check-migration-column-preservation.sh           # diff vs main
#   scripts/ci/check-migration-column-preservation.sh --all     # scan all
#
# Exit codes
# ----------
#   0 - always (this is a nudge, not a gate). When the script finds
#       RETURNS TABLE blocks in changed migration files it prints a warning
#       block; CI workflows can pipe that into a PR comment.
# ----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

MODE="${1:-diff}"
MIGRATIONS_DIR="supabase/migrations"

if [[ ! -d "${MIGRATIONS_DIR}" ]]; then
  echo "No ${MIGRATIONS_DIR} directory — skipping."
  exit 0
fi

# Determine which migration files to inspect.
files=()
case "${MODE}" in
  --all|all)
    while IFS= read -r f; do
      files+=("${f}")
    done < <(find "${MIGRATIONS_DIR}" -maxdepth 1 -type f -name '*.sql' | sort)
    ;;
  diff|*)
    # Default: every migration file changed in the current diff vs origin/main.
    base="${BASE_REF:-origin/main}"
    if ! git rev-parse --verify "${base}" >/dev/null 2>&1; then
      base="HEAD~1"
    fi
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      files+=("${f}")
    done < <(git diff --name-only "${base}"...HEAD -- "${MIGRATIONS_DIR}/*.sql" 2>/dev/null || true)
    ;;
esac

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No migration files in scope. OK."
  exit 0
fi

flagged=()
for f in "${files[@]}"; do
  [[ -f "${f}" ]] || continue
  # Pull the lines that start a CREATE OR REPLACE FUNCTION block and have
  # RETURNS TABLE somewhere in their body. We use a python-free awk pass to
  # extract function name + line number for each block.
  awk '
    BEGIN { in_block = 0; block = ""; block_start = 0 }
    /CREATE[[:space:]]+OR[[:space:]]+REPLACE[[:space:]]+FUNCTION/ {
      in_block = 1
      block_start = NR
      block = $0
      next
    }
    in_block {
      block = block "\n" $0
      # End of function header is when we hit the body marker `AS $$` or `AS $function$`.
      if ($0 ~ /AS[[:space:]]+\$[A-Za-z_]*\$/) {
        if (block ~ /RETURNS[[:space:]]+TABLE/) {
          # Extract function name.
          match(block, /FUNCTION[[:space:]]+[A-Za-z_.]+/)
          if (RSTART > 0) {
            name = substr(block, RSTART + 9, RLENGTH - 9)
            sub(/^[[:space:]]+/, "", name)
            print block_start ":" name
          }
        }
        in_block = 0
        block = ""
      }
    }
  ' "${f}" | while IFS= read -r hit; do
    [[ -z "${hit}" ]] && continue
    lineno="${hit%%:*}"
    name="${hit#*:}"
    echo "::warning file=${f},line=${lineno}::CREATE OR REPLACE FUNCTION ${name} returns a TABLE. Verify every column from the prior definition is preserved. See docs/CI.md §10 and feedback_schema_migration_column_preservation.md."
    echo "  ${f}:${lineno}  ${name}  (RETURNS TABLE)"
  done
done

cat <<EOF

----------------------------------------------------------------------------
Migration nudge
----------------------------------------------------------------------------
If any CREATE OR REPLACE FUNCTION ... RETURNS TABLE entries are flagged
above, manually verify each preserves ALL columns from its prior definition.

Pre-flight check (run locally against the live DB):

    psql -At -c "\\df+ public.<fn_name>" <DB_URL>

OR via Supabase MCP:

    SELECT pg_get_functiondef('public.<fn_name>'::regprocedure);

Compare the existing RETURNS TABLE column list against your new one. A
silently dropped column is the bug — it broke sticky defaults and
avatars in Wave 40.5; don't repeat it.
----------------------------------------------------------------------------
EOF

exit 0
