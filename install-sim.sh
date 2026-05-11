#!/bin/bash
# homefit.studio — simulator reset + fresh install
# Purpose: wipe Supabase session (so the app lands on the Sign-In screen),
# rebuild, and relaunch on the iPhone 16e simulator. Useful for brand
# screenshots and any time you want a "first launch" experience.
#
# ENV-aware (docs/CI.md §5):
#   Default behaviour is ENV=branch — reads current git branch, looks up
#   the matching Supabase preview branch DB via the CLI, injects the URL
#   + anon key at build time. If no matching Supabase branch exists,
#   falls back to the persistent `staging` branch DB.
#
#   Override with the first positional argument:
#     ./install-sim.sh              # ENV=branch (default)
#     ./install-sim.sh staging      # ENV=staging — pin to staging branch DB
#     ./install-sim.sh prod         # ENV=prod   — pin to prod (caution!)
#
# Strict-fail: if a non-prod build can't resolve a Supabase URL + anon
# key, the script exits non-zero. Mirrors the web-player build.sh policy
# (PR #293) — no silent fallback to prod from a feature branch.
set -euo pipefail   # pipefail so `cmd | tail` doesn't mask cmd's failure

DEVICE=E4285EC5-6210-4D27-B3AF-F63ADDE139D9
BUNDLE=studio.homefit.app
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${REPO_ROOT}/app/build/ios/iphonesimulator/Runner.app"

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

# Staging persistent branch (see docs/CI.md §10 — created during the CI/CD
# automation PR, persistent=true so it survives PR merges).
STAGING_PROJECT_REF=vadjvkmldtoeyspyoqbx

# Helper: fetch the publishable (sb_publishable_*) key for a given
# project ref via the Supabase Management API (CLI uses the Personal
# Access Token from the macOS Keychain, populated by `supabase login`).
fetch_anon_key() {
  local ref="$1"
  supabase projects api-keys --project-ref "$ref" --output json 2>/dev/null \
    | python3 -c "
import sys, json
keys = json.load(sys.stdin)
# Prefer the new publishable shape; fall back to legacy anon JWT if
# the project hasn't been issued one yet.
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
      # Query branches list for a Supabase branch matching the git
      # branch name. Strict-fail philosophy: if not found, fall back to
      # the persistent staging branch so the build still has SOMETHING
      # to point at. Without a fallback, every fresh feature branch
      # would require waiting for the GitHub App to provision a branch
      # DB before install-sim could run.
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

echo "▸ Booting simulator (if not already booted)..."
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

echo "▸ Uninstalling existing app (clears Supabase session → back to Sign-In)..."
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true

echo "▸ Syncing web-player bundle into Flutter assets (R-10 parity)..."
# Without this, app/assets/web-player/* drifts behind web-player/* and
# the simulator preview ships stale bytes. Same step as install-device.sh.
cd "${REPO_ROOT}/app"
dart run tool/sync_web_player_bundle.dart

echo "▸ Building Flutter app for simulator (first run ≈ 2-3 min)..."
cd "${REPO_ROOT}/app"
# Bakes short git SHA into AppConfig.buildSha so the Pulse Mark footer
# renders a tiny muted build marker — lets us verify which commit is
# actually installed after a rebuild.
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ios --debug --simulator \
  --dart-define=GIT_SHA="$GIT_SHA" \
  --dart-define=ENV="$ENV_FLAG" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

echo "▸ Installing fresh build..."
xcrun simctl install "$DEVICE" "$APP_PATH"

echo "▸ Launching app..."
xcrun simctl launch "$DEVICE" "$BUNDLE"

echo "✓ Done. Simulator is on the Sign-In screen (ENV=$ENV_FLAG)."
