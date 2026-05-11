#!/bin/bash
# homefit.studio — physical device install (iPhone CHM)
#
# Purpose: build current branch, install on Carl's physical iPhone.
#
# As of 2026-04-18, NordVPN + Xcode device tunnel coexist — run this
# straight through, no VPN dance. iPhone plugged in via USB + unlocked
# is all that's needed. If device-tunnel ever regresses after a NordVPN
# update, the historic workaround was "VPN off for the install window";
# see memory/vpn_api_constraint.md.
#
# ENV-aware (docs/CI.md §5):
#   Default behaviour is ENV=branch — reads current git branch, looks up
#   the matching Supabase preview branch DB via the CLI, injects the URL
#   + anon key at build time. If no matching Supabase branch exists,
#   falls back to the persistent `staging` branch DB.
#
#   Override with the first positional argument:
#     ./install-device.sh             # ENV=branch (default) — current git branch
#     ./install-device.sh staging     # ENV=staging — pin to staging branch DB
#     ./install-device.sh prod        # ENV=prod   — pin to prod (caution!)
#
#   ENV=prod is the historic "pull main + build" path. ENV=branch /
#   staging skip `git pull` entirely — they build whatever's checked
#   out so feature-branch testing works without needing to merge.
#
# Strict-fail: if a non-prod build can't resolve a Supabase URL + anon
# key, the script exits non-zero. Mirrors the web-player build.sh policy
# (PR #293) — no silent fallback to prod from a feature branch.
set -euo pipefail   # pipefail so `cmd | tail` doesn't mask cmd's failure

DEVICE=00008150-001A31D40E88401C   # iPhone CHM
BUNDLE=studio.homefit.app
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${REPO_ROOT}/app/build/ios/iphoneos/Runner.app"

# Resolve ENV — default to 'branch'.
ENV_FLAG="${1:-branch}"
case "$ENV_FLAG" in
  prod|staging|branch) ;;
  *)
    echo "error: unknown ENV: $ENV_FLAG (expected: prod | staging | branch)" >&2
    exit 2
    ;;
esac

# ----------------------------------------------------------------------------
# Resolve SUPABASE_URL + SUPABASE_ANON_KEY based on ENV.
# ----------------------------------------------------------------------------
# Prod values mirror AppConfig._prodSupabaseUrl / _prodSupabaseAnonKey.
PROD_PROJECT_REF=yrwcofhovrcydootivjx
PROD_SUPABASE_URL="https://${PROD_PROJECT_REF}.supabase.co"
PROD_SUPABASE_ANON_KEY='sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3'

# Staging persistent branch.
STAGING_PROJECT_REF=vadjvkmldtoeyspyoqbx

# Helper: fetch the publishable (sb_publishable_*) key for a given
# project ref via the Supabase Management API (CLI uses the Personal
# Access Token from the macOS Keychain).
fetch_anon_key() {
  local ref="$1"
  supabase projects api-keys --project-ref "$ref" --output json 2>/dev/null \
    | python3 -c "
import sys, json
keys = json.load(sys.stdin)
for k in keys:
    if k.get('type') == 'publishable':
        print(k['api_key'])
        sys.exit(0)
for k in keys:
    if k.get('id') == 'anon' or k.get('name') == 'anon':
        print(k['api_key'])
        sys.exit(0)
sys.exit(1)
"
}

resolve_env() {
  case "$ENV_FLAG" in
    prod)
      SUPABASE_URL="$PROD_SUPABASE_URL"
      SUPABASE_ANON_KEY="$PROD_SUPABASE_ANON_KEY"
      ;;
    staging)
      SUPABASE_URL="https://${STAGING_PROJECT_REF}.supabase.co"
      SUPABASE_ANON_KEY="$(fetch_anon_key "$STAGING_PROJECT_REF")" || {
        echo "ERROR: could not fetch anon key for staging branch (${STAGING_PROJECT_REF})." >&2
        echo "       Is the Supabase CLI logged in? Run \`supabase login\`." >&2
        exit 1
      }
      ;;
    branch)
      local git_branch
      git_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
      echo "▸ ENV=branch — current git branch: $git_branch" >&2
      local branches_json
      branches_json="$(supabase branches list --project-ref "$PROD_PROJECT_REF" --output json 2>/dev/null)" || {
        echo "ERROR: \`supabase branches list\` failed. CLI logged in?" >&2
        exit 1
      }
      local branch_ref
      branch_ref="$(printf '%s' "$branches_json" \
        | GIT_BRANCH="$git_branch" python3 -c "
import sys, json, os
branches = json.load(sys.stdin)
target = os.environ['GIT_BRANCH']
for b in branches:
    if b.get('git_branch') == target or b.get('name') == target:
        print(b['project_ref'])
        sys.exit(0)
")" || branch_ref=""

      if [[ -n "$branch_ref" ]]; then
        echo "▸ Found matching Supabase branch: $branch_ref" >&2
        SUPABASE_URL="https://${branch_ref}.supabase.co"
        SUPABASE_ANON_KEY="$(fetch_anon_key "$branch_ref")" || {
          echo "ERROR: could not fetch anon key for branch ref $branch_ref." >&2
          exit 1
        }
      else
        echo "▸ No Supabase branch matches '$git_branch' — falling back to persistent staging." >&2
        SUPABASE_URL="https://${STAGING_PROJECT_REF}.supabase.co"
        SUPABASE_ANON_KEY="$(fetch_anon_key "$STAGING_PROJECT_REF")" || {
          echo "ERROR: could not fetch anon key for staging branch fallback (${STAGING_PROJECT_REF})." >&2
          echo "       The CLI must be logged in (\`supabase login\`) and the" >&2
          echo "       Personal Access Token must have access to the prod project." >&2
          exit 1
        }
      fi
      ;;
  esac

  echo "▸ ENV=$ENV_FLAG  →  $SUPABASE_URL" >&2
  echo "▸                  anon key: ${SUPABASE_ANON_KEY:0:24}..." >&2
}

resolve_env

if [[ "$ENV_FLAG" == "prod" ]]; then
  # Historic prod path — pulls latest main before building. The default
  # ENV=branch path skips this so feature-branch testing works without
  # needing the branch to be merged into main first.
  echo "▸ ENV=prod — pulling latest main..."
  cd "$REPO_ROOT"
  git pull origin main
fi

echo "▸ Syncing web-player bundle into Flutter assets (R-10 parity)..."
# Without this, app/assets/web-player/* drifts behind web-player/* and the
# WebView preview ships stale bytes. 2026-04-25 — this had silently left
# the iPhone unified preview on pre-Wave-21 web-player code for weeks.
cd "${REPO_ROOT}/app"
dart run tool/sync_web_player_bundle.dart

echo "▸ Building Flutter app for physical device in PROFILE mode (first run ≈ 5-8 min)..."
# Profile mode — not release — during QA. Debug mode is rejected by iOS
# 14+ for standalone launch ("Cannot create a FlutterEngine instance in
# debug mode without Flutter tooling or Xcode"), but PROFILE is AOT-
# compiled AND retains `debugPrint` / stdout so logs still show up via
# `idevicesyslog`. Release mode strips those, which made us blind when
# diagnosing the raw-archive silent upload failure (2026-04-20).
#
# Passing the current short git SHA via --dart-define bakes it into
# AppConfig.buildSha, which the Settings footer (post-Wave-3) renders
# as a tiny muted label. Confirms at a glance which commit is on-device
# after a rebuild.
cd "${REPO_ROOT}/app"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ios --profile \
  --dart-define=GIT_SHA="$GIT_SHA" \
  --dart-define=ENV="$ENV_FLAG" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

echo "▸ Installing to iPhone CHM..."
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"

echo "✓ Done. Open homefit.studio on your phone (ENV=$ENV_FLAG)."
