#!/usr/bin/env bash
# check-no-direct-db-access.sh
# ----------------------------------------------------------------------------
# Enforces the "no direct DB access" hard rule from
# docs/DATA_ACCESS_LAYER.md and the feedback_no_direct_db_access.md memory.
#
# Every read/write to Supabase MUST go through the per-surface access layer:
#   - app/lib/services/api_client.dart                  (Flutter)
#   - web-portal/src/lib/supabase/*.ts                  (Next.js portal)
#   - web-player/api.js (+ middleware.js for OG unfurl) (static web player)
#   - supabase/functions/**                             (Edge Functions)
#
# Forbidden patterns outside the allowed files:
#   - `supabase.from(...)` or `.from(...)` chained on a supabase client (TS/JS)
#   - `Supabase.instance.client` (Dart)
#   - `/rest/v1/` literal in JS (raw PostgREST URL)
#
# Grandfather mechanism
# ---------------------
# Existing violations recorded in scripts/ci/db-access-exceptions.txt are
# ignored. NEW violations fail CI. To clean up tech debt, route an offending
# call through the access layer and delete its line from the exceptions file.
# Goal: empty exceptions file.
#
# The companion Python checker at tools/enforce_data_access_seams.py is the
# more capable variant (it scans line content with context); this bash script
# is the lightweight CI gate that matches the brief shape and is fast enough
# to run as a quick local pre-commit.
#
# Usage
# -----
#   scripts/ci/check-no-direct-db-access.sh
#
# Exit codes:
#   0 - clean (no new violations)
#   1 - new violations found
# ----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

EXCEPTIONS_FILE="scripts/ci/db-access-exceptions.txt"

# Allowed files where direct DB access IS permitted.
# Stored as exact repo-relative paths. Globs handled separately below.
ALLOWED_EXACT=(
  "app/lib/services/api_client.dart"
  "web-portal/src/lib/supabase/api.ts"
  "web-portal/src/lib/supabase/database.types.ts"
  "web-player/api.js"
  "web-player/middleware.js"
)

# Allowed path prefixes (everything under these is whitelisted).
ALLOWED_PREFIXES=(
  "web-portal/src/lib/supabase/"
  "supabase/functions/"
  # Native bundled vendor file — not our code.
  "web-player/html2canvas.min.js"
)

is_allowed() {
  local path="$1"
  for exact in "${ALLOWED_EXACT[@]}"; do
    if [[ "${path}" == "${exact}" ]]; then
      return 0
    fi
  done
  for prefix in "${ALLOWED_PREFIXES[@]}"; do
    if [[ "${path}" == "${prefix}"* ]]; then
      return 0
    fi
  done
  return 1
}

# Load grandfather exceptions. Stored as one path per line in a newline-
# delimited string for portability (macOS bash 3.2 lacks associative arrays).
EXCEPTIONS_LIST=""
if [[ -f "${EXCEPTIONS_FILE}" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Strip comments + blank lines.
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "${line}" ]]; then
      EXCEPTIONS_LIST+="${line}"$'\n'
    fi
  done < "${EXCEPTIONS_FILE}"
fi

is_exception() {
  local path="$1"
  [[ -n "${EXCEPTIONS_LIST}" ]] || return 1
  # Whole-line match using grep.
  printf '%s' "${EXCEPTIONS_LIST}" | grep -Fxq "${path}"
}

violations=()

scan_file() {
  local path="$1"
  local pattern="$2"

  if is_allowed "${path}"; then
    return
  fi
  if is_exception "${path}"; then
    return
  fi

  # grep -n returns "LINE:CONTENT"; suppress error when no match.
  local hits
  if hits="$(grep -nE "${pattern}" "${path}" 2>/dev/null)"; then
    while IFS= read -r hit; do
      [[ -z "${hit}" ]] && continue
      local lineno="${hit%%:*}"
      local content="${hit#*:}"
      # Skip obvious comment lines so doc examples don't trip the check.
      local stripped
      stripped="$(echo "${content}" | sed 's/^[[:space:]]*//')"
      case "${stripped}" in
        //*|/\**|\**|\*\/*|'///'*) continue ;;
      esac
      violations+=("${path}:${lineno}: ${stripped}")
    done <<< "${hits}"
  fi
}

# ---------------------------------------------------------------------------
# TypeScript / TSX: pattern is `.from(` or `.rpc(` or `.storage` chained
# directly off a supabase client identifier. We grep loosely and let the
# allowed-files filter do the precise work.
# ---------------------------------------------------------------------------
while IFS= read -r path; do
  scan_file "${path}" 'supabase[[:space:]]*\.[[:space:]]*(from|rpc|storage)[[:space:]]*\('
done < <(find web-portal/src -type f \( -name '*.ts' -o -name '*.tsx' \) 2>/dev/null || true)

# ---------------------------------------------------------------------------
# JavaScript (web-player): forbid `/rest/v1/` direct URLs and `.from(` chained
# off a supabase client. middleware.js is whitelisted above for the bot
# unfurl carve-out.
# ---------------------------------------------------------------------------
while IFS= read -r path; do
  scan_file "${path}" '/rest/v1/'
  scan_file "${path}" 'supabase[[:space:]]*\.[[:space:]]*(from|rpc|storage)[[:space:]]*\('
done < <(find web-player -maxdepth 1 -type f -name '*.js' 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Dart: forbid `Supabase.instance.client` outside api_client.dart. The
# auth/upload services route through ApiClient.instance; nothing else may
# touch the raw client.
# ---------------------------------------------------------------------------
while IFS= read -r path; do
  scan_file "${path}" 'Supabase\.instance\.client'
done < <(find app/lib -type f -name '*.dart' 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [[ ${#violations[@]} -eq 0 ]]; then
  echo "OK: no new direct-DB-access violations."
  exit 0
fi

echo "ERROR: ${#violations[@]} new direct-DB-access violation(s) found."
echo ""
echo "All Supabase access must go through the per-surface access layer."
echo "See docs/DATA_ACCESS_LAYER.md."
echo ""
echo "Violations:"
for v in "${violations[@]}"; do
  echo "  ${v}"
done
echo ""
echo "If a violation is a true exception (not just unrouted code), add the"
echo "file path to ${EXCEPTIONS_FILE} with a comment justifying it."
exit 1
