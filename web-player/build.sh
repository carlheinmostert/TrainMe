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
#   When the env vars are absent, the script writes a `config.js` that
#   points at the prod Supabase project. This preserves Carl's existing
#   "open the file in a browser" workflow. The runtime fallback in
#   `api.js` covers the case where `config.js` is missing entirely
#   (e.g. the bundle is loaded as `rootBundle` assets inside the
#   Flutter-embedded LocalPlayerServer, which never reaches Supabase
#   anyway thanks to `isLocalSurface()`).
#
# Exit codes:
#   0 — config.js written
#   non-zero on filesystem failure (env vars missing is NOT an error;
#   we fall back to prod)
# ----------------------------------------------------------------------------

set -euo pipefail

# Resolve the directory this script lives in so we emit config.js next to
# the other web-player files regardless of where Vercel runs us from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/config.js"

# Prod fallback values — match the legacy hardcoded constants. If the
# env vars are missing (local dev, or a misconfigured deployment), the
# generated config.js still works against production data. This is
# deliberately lenient; a stricter "fail-build-if-env-missing" stance
# would catch misconfigured deployments earlier but break Carl's local
# file:// workflow.
FALLBACK_URL='https://yrwcofhovrcydootivjx.supabase.co'
FALLBACK_KEY='sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3'

SUPABASE_URL="${NEXT_PUBLIC_SUPABASE_URL:-${FALLBACK_URL}}"
# Prefer the new publishable-key shape; fall back to the legacy anon key
# name if only that's present in the env.
SUPABASE_ANON_KEY="${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:-${NEXT_PUBLIC_SUPABASE_ANON_KEY:-${FALLBACK_KEY}}}"

# Identify whether we're using env-provided or fallback values, for the
# build log. Useful when sanity-checking a Vercel deployment.
SOURCE_URL='env'
SOURCE_KEY='env'
[[ "${SUPABASE_URL}"      == "${FALLBACK_URL}" ]] && SOURCE_URL='fallback'
[[ "${SUPABASE_ANON_KEY}" == "${FALLBACK_KEY}" ]] && SOURCE_KEY='fallback'

echo "web-player/build.sh — writing ${OUTPUT}"
echo "  SUPABASE_URL: ${SUPABASE_URL} (source: ${SOURCE_URL})"
echo "  SUPABASE_ANON_KEY: ${SUPABASE_ANON_KEY:0:24}... (source: ${SOURCE_KEY})"

# Escape any single quotes in the values for safe embedding inside a
# single-quoted JS string literal. Replace ' with '\''.
ESC_URL="${SUPABASE_URL//\'/\\\'}"
ESC_KEY="${SUPABASE_ANON_KEY//\'/\\\'}"

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
 * Source: ${SOURCE_URL}/${SOURCE_KEY} (env or fallback to prod)
 */
window.HOMEFIT_CONFIG = Object.freeze({
  supabaseUrl: '${ESC_URL}',
  supabaseAnonKey: '${ESC_KEY}',
});
EOF

echo "web-player/build.sh — done"
