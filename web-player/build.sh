#!/usr/bin/env bash
# web-player/build.sh
# ----------------------------------------------------------------------------
# Vercel build step for the static web player. Writes a generated
# `config.js` that exposes the Supabase URL + anon key to the browser
# bundle via `window.HOMEFIT_CONFIG`. Reads from Vercel-injected env vars
# so each deployment (production / preview / per-branch) automatically
# wires up the right Supabase project — including per-PR branch DBs once
# Supabase Branching is enabled.
#
# This file is the ONLY build-time machinery for the web player. There is
# no bundler, no compile step — just a one-shot config-file emit.
#
# Env vars (provided by the Supabase-Vercel integration):
#   NEXT_PUBLIC_SUPABASE_URL              required (URL of the project)
#   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY  preferred (new `sb_publishable_*`
#                                                    shape — matches what
#                                                    the legacy hardcoded
#                                                    value was)
#   NEXT_PUBLIC_SUPABASE_ANON_KEY         fallback  (legacy JWT-format
#                                                    anon key — also
#                                                    accepted by Supabase)
#
# Local dev (file://, `python -m http.server`, etc.):
#   STRICT-FAIL policy (2026-05-11): no fallback to prod values. If env
#   vars are missing the script exits non-zero with a clear error.
#   Misconfigured deployments fail loudly instead of silently routing to
#   prod. For local dev that needs a working web-player, either:
#     (a) run `vercel dev` (injects env vars), or
#     (b) export NEXT_PUBLIC_SUPABASE_URL +
#         NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY before calling this
#         script directly.
#   The Flutter-embedded LocalPlayerServer surface doesn't run this
#   script — it serves an inert empty config via the Swift scheme
#   handler, and `isLocalSurface()` in api.js short-circuits all network
#   calls before SUPABASE_URL is read.
#
# Exit codes:
#   0 — config.js written
#   1 — required env var missing, or filesystem failure
# ----------------------------------------------------------------------------

set -euo pipefail

# Resolve the directory this script lives in so we emit config.js next to
# the other web-player files regardless of where Vercel runs us from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/config.js"

# Strict-fail: env vars are required. No prod fallback.
if [[ -z "${NEXT_PUBLIC_SUPABASE_URL:-}" ]]; then
  echo "ERROR: NEXT_PUBLIC_SUPABASE_URL is not set." >&2
  echo "       The Vercel-Supabase integration must be configured for this" >&2
  echo "       deployment environment. For local dev, run \`vercel dev\` or" >&2
  echo "       export the env vars manually before invoking build.sh." >&2
  exit 1
fi

SUPABASE_URL="${NEXT_PUBLIC_SUPABASE_URL}"
# Prefer the new publishable-key shape; fall back to the legacy anon key
# name if only that's present. At least one must be set.
SUPABASE_ANON_KEY="${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:-${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}}"

if [[ -z "${SUPABASE_ANON_KEY}" ]]; then
  echo "ERROR: Neither NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY nor" >&2
  echo "       NEXT_PUBLIC_SUPABASE_ANON_KEY is set. At least one must be" >&2
  echo "       present (the Vercel-Supabase integration provides both)." >&2
  exit 1
fi

# Build-marker plumbing — surface git SHA + branch into the bundle so
# `app.js` + `lobby.js` can render "<sha> · <branch>" alongside the
# existing PLAYER_VERSION constant. Vercel auto-injects
# VERCEL_GIT_COMMIT_SHA + VERCEL_GIT_COMMIT_REF on every build; locally
# we fall back to `git rev-parse` so `vercel dev` and bare shell
# invocations still emit a sensible marker.
GIT_SHA_RAW="${VERCEL_GIT_COMMIT_SHA:-$(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo dev)}"
GIT_SHA="${GIT_SHA_RAW:0:7}"
GIT_BRANCH="${VERCEL_GIT_COMMIT_REF:-$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)}"

echo "web-player/build.sh — writing ${OUTPUT}"
echo "  SUPABASE_URL: ${SUPABASE_URL}"
echo "  SUPABASE_ANON_KEY: ${SUPABASE_ANON_KEY:0:24}..."
echo "  GIT_SHA: ${GIT_SHA}"
echo "  GIT_BRANCH: ${GIT_BRANCH}"

# Escape any single quotes in the values for safe embedding inside a
# single-quoted JS string literal. Replace ' with '\''.
ESC_URL="${SUPABASE_URL//\'/\\\'}"
ESC_KEY="${SUPABASE_ANON_KEY//\'/\\\'}"
ESC_SHA="${GIT_SHA//\'/\\\'}"
ESC_BRANCH="${GIT_BRANCH//\'/\\\'}"

cat > "${OUTPUT}" <<EOF
/**
 * homefit.studio — web-player runtime config
 *
 * GENERATED FILE — DO NOT EDIT BY HAND.
 *
 * Emitted by web-player/build.sh from Vercel-injected env vars. Loaded
 * BEFORE api.js so the Supabase URL + anon key can be picked up via
 * window.HOMEFIT_CONFIG instead of being hardcoded into the bundle.
 *
 * Strict-fail: build.sh exits non-zero if env vars are missing, so
 * reaching this template means real env values are present.
 *
 * gitSha + gitBranch are best-effort — they fall back to 'dev' / 'local'
 * when neither Vercel env vars nor a local git checkout are available.
 * The build-marker chip rendered by app.js / lobby.js degrades
 * gracefully to those literals so the chip still shows on any host.
 */
window.HOMEFIT_CONFIG = Object.freeze({
  supabaseUrl: '${ESC_URL}',
  supabaseAnonKey: '${ESC_KEY}',
  gitSha: '${ESC_SHA}',
  gitBranch: '${ESC_BRANCH}',
});
EOF

# ----------------------------------------------------------------------------
# Service-worker cache-name SHA injection
# ----------------------------------------------------------------------------
# `sw.js` declares CACHE_NAME = 'homefit-player-__BUILD_SHA__' and we rewrite
# the sentinel to the 7-char GIT_SHA in-place so every deploy ships a unique
# cache name. Without this, the SW happily serves stale HTML / headers / CSP
# from the cache long after the developer ships a fix — both real outages on
# 2026-05-12 traced back to a stale SW cache. The sentinel is distinctive
# enough to avoid false matches.
#
# Portable replacement strategy: write to a temp file then mv, which works
# identically on Vercel's Linux runtime and macOS local dev (vs. `sed -i`
# which has incompatible flag syntax across the two).
SW_FILE="${SCRIPT_DIR}/sw.js"
SW_TMP="${SW_FILE}.tmp"
if grep -q "__BUILD_SHA__" "${SW_FILE}"; then
  sed "s/__BUILD_SHA__/${GIT_SHA}/g" "${SW_FILE}" > "${SW_TMP}"
  mv "${SW_TMP}" "${SW_FILE}"
  echo "  sw.js CACHE_NAME → homefit-player-${GIT_SHA}"
else
  echo "  sw.js CACHE_NAME → (no __BUILD_SHA__ sentinel found; leaving as-is)" >&2
fi

echo "web-player/build.sh — done"
