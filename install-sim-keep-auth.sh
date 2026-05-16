#!/bin/bash
# homefit.studio — simulator rebuild + install WITHOUT wiping auth
# Purpose: rebuild the Flutter app and re-install it on the iPhone 16e
# simulator while PRESERVING the Supabase session in Keychain. Useful
# for agent-driven QA and any iteration loop where you want to land
# inside the app (Clients / Studio) instead of the Sign-In screen.
#
# Difference vs install-sim.sh:
#   install-sim.sh            : `xcrun simctl uninstall` first -> lands on Sign-In
#   install-sim-keep-auth.sh  : skips uninstall -> lands on whatever screen the
#                               app was on last (typically Clients / Studio)
#
# When to use which:
#   install-sim.sh             — fresh-start QA, screenshots of the Sign-In
#                                screen, anything that needs the bootstrap flow.
#   install-sim-keep-auth.sh   — agent QA runs (per docs/AGENT_QA_AUTH.md),
#                                rapid iteration on Studio / Clients UI, any
#                                time you don't want to retype the password.
#
# Auth persistence model: Supabase stores the refresh token in iOS
# Keychain. Keychain entries survive app reinstall (when the bundle
# identifier matches), so simply skipping the uninstall step keeps the
# practitioner signed in. Refresh tokens last ~30 days; after that the
# next launch lands on Sign-In and the agent must re-authenticate with
# the credentials in .env.test. See docs/AGENT_QA_AUTH.md.
#
# ENV-aware: same behaviour as install-sim.sh — first positional arg
# selects the Supabase environment (branch | staging | prod). Defaults
# to ENV=branch.
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
# (Logic mirrored from install-sim.sh — kept as a separate file so the
# canonical sign-in-screen behaviour stays untouched.)
# ----------------------------------------------------------------------------
PROD_PROJECT_REF=yrwcofhovrcydootivjx
PROD_SUPABASE_URL="https://${PROD_PROJECT_REF}.supabase.co"
PROD_SUPABASE_ANON_KEY='sb_publishable_cwhfavfji552BN8X0uPIpA_pwWQ-gw3'

STAGING_PROJECT_REF=vadjvkmldtoeyspyoqbx

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
      echo "> ENV=branch — current git branch: $git_branch" >&2
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
        echo "> Found matching Supabase branch: $branch_ref" >&2
        SUPABASE_URL="https://${branch_ref}.supabase.co"
        SUPABASE_ANON_KEY="$(fetch_anon_key "$branch_ref")" || {
          echo "ERROR: could not fetch anon key for branch ref $branch_ref." >&2
          exit 1
        }
      else
        echo "> No Supabase branch matches '$git_branch' — falling back to persistent staging." >&2
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

  echo "> ENV=$ENV_FLAG  ->  $SUPABASE_URL" >&2
  echo ">                  anon key: ${SUPABASE_ANON_KEY:0:24}..." >&2
}

resolve_env

echo "> Booting simulator (if not already booted)..."
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

# Deliberately NO `xcrun simctl uninstall` here — that's the only
# difference from install-sim.sh. Keeping the existing app bundle in
# place preserves the Keychain entry that Supabase uses to persist the
# session refresh token.

echo "> Syncing web-player bundle into Flutter assets (R-10 parity)..."
cd "${REPO_ROOT}/app"
dart run tool/sync_web_player_bundle.dart

echo "> Building Flutter app for simulator (first run ~2-3 min)..."
cd "${REPO_ROOT}/app"
GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
LC_ALL=en_US.UTF-8 flutter build ios --debug --simulator \
  --dart-define=GIT_SHA="$GIT_SHA" \
  --dart-define=ENV="$ENV_FLAG" \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"

echo "> Installing build over existing app (Keychain preserved)..."
xcrun simctl install "$DEVICE" "$APP_PATH"

echo "> Launching app..."
xcrun simctl launch "$DEVICE" "$BUNDLE"

echo "Done. Simulator launched with previous session preserved (ENV=$ENV_FLAG)."
echo "If the session has expired (~30 days), sign in with credentials from .env.test."
