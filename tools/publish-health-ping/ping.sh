#!/bin/bash
# Wave 7 / Milestone Q — daily publish-health ping.
#
# Queries the `publish_health` SQL view (see
# supabase/schema_milestone_q_error_logs.sql) and formats a one-liner
# WhatsApp message for Carl via CallMeBot.
#
# Design review: docs/design-reviews/silent-failures-2026-04-20.md
# ("Observability — 3-item MVP", item 3).
#
# -------------------------------------------------------------------------
# INPUTS
# -------------------------------------------------------------------------
#
#   - SUPABASE_URL           (e.g. https://yrwcofhovrcydootivjx.supabase.co)
#   - SUPABASE_SERVICE_KEY   (service role key; required for table reads)
#   - CALLMEBOT_PHONE        (e.g. +27712345678)
#   - CALLMEBOT_APIKEY       (issued by CallMeBot at setup time)
#
# Set via env vars or copy the template at `.env.example` to `.env`. The
# script sources `.env` if it exists.
#
# -------------------------------------------------------------------------
# USAGE
# -------------------------------------------------------------------------
#
#   ./ping.sh          # queries + posts
#   ./ping.sh --dry    # queries only, prints the message locally
#
# -------------------------------------------------------------------------
# SCHEDULING
# -------------------------------------------------------------------------
#
# Two easy options, use whichever lands first:
#
# 1. Local cron on Carl's Mac:
#      crontab -e
#      # Daily 08:00 local time:
#      0 8 * * * cd /Users/chm/dev/TrainMe/tools/publish-health-ping && ./ping.sh
#
# 2. Supabase scheduled function: wrap this logic in an edge function
#    (deno runtime, similar shape to supabase/functions/payfast-webhook)
#    and register via `supabase functions schedule`. Service role key
#    lives in the function's env; CallMeBot credentials also stored
#    server-side. This is the real production path — deferred until
#    Carl has >1 user depending on the signal.
#
# TODO(wave-7): wire the Supabase scheduled-function option once Carl
# signs off on the CallMeBot credentials landing in Supabase project env.
# For now, local cron on the Mac is the shipping plan.
#
# -------------------------------------------------------------------------

set -euo pipefail

cd "$(dirname "$0")"

# Load env from .env if present (don't fail if absent; we also accept
# environment inheritance).
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DRY_RUN=0
if [[ "${1:-}" == "--dry" || "${1:-}" == "-n" ]]; then
  DRY_RUN=1
fi

# Required inputs. Script refuses to run without credentials — better a
# noisy "you haven't set this up yet" than a silently no-op ping.
: "${SUPABASE_URL:?SUPABASE_URL is not set — copy .env.example to .env}"
: "${SUPABASE_SERVICE_KEY:?SUPABASE_SERVICE_KEY is not set}"
if [[ $DRY_RUN -eq 0 ]]; then
  : "${CALLMEBOT_PHONE:?CALLMEBOT_PHONE is not set (use --dry to skip)}"
  : "${CALLMEBOT_APIKEY:?CALLMEBOT_APIKEY is not set (use --dry to skip)}"
fi

# Strip trailing slash from the URL.
url="${SUPABASE_URL%/}"

# ----------------------------------------------------------------
# 1. Query the publish_health view via PostgREST.
# ----------------------------------------------------------------
# Service role key bypasses RLS so we can see every practice in one go.
# The view is already grouped by practice_id; we aggregate on the
# client side into a single summary row.
resp=$(
  curl -sS \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H 'Accept: application/json' \
    "${url}/rest/v1/publish_health?select=practice_id,stuck_pending,failed_24h,succeeded_24h,last_issued_ts"
)

if [[ -z "$resp" || "$resp" == "null" ]]; then
  echo "publish_health query returned empty payload — aborting"
  exit 1
fi

# ----------------------------------------------------------------
# 2. Summarise with jq. No additional deps — jq is on every Mac since
#    macOS 12 (installable via brew).
# ----------------------------------------------------------------
# Summary rules:
#   * practices_total                — rows returned by the view.
#   * practices_stuck                — rows with stuck_pending > 0.
#   * stuck_pending_total            — sum across fleet.
#   * failed_24h_total               — sum across fleet.
#   * succeeded_24h_total            — sum across fleet.
#   * max_last_issued                — most recent publish anywhere.
summary=$(echo "$resp" | jq -r '
  (length)                                       as $total |
  ([.[] | select(.stuck_pending > 0)] | length)  as $stuck |
  ([.[] | .stuck_pending]      | add // 0)       as $stuck_sum |
  ([.[] | .failed_24h]         | add // 0)       as $failed_sum |
  ([.[] | .succeeded_24h]      | add // 0)       as $succ_sum |
  ([.[] | .last_issued_ts] | map(select(.)) | max // "never") as $max_ts |
  "\($total)|\($stuck)|\($stuck_sum)|\($failed_sum)|\($succ_sum)|\($max_ts)"
')

IFS='|' read -r practices_total practices_stuck stuck_sum failed_sum succ_sum max_ts <<< "$summary"

# ----------------------------------------------------------------
# 3. Compose the WhatsApp message.
# ----------------------------------------------------------------
# Keep it short — WhatsApp previews 3 lines by default. Leading emoji
# is intentional so an alert jumps out of a message list. If everything
# is clean, a green heart; otherwise a flashing red.
if [[ "$practices_stuck" == "0" && "$stuck_sum" == "0" ]]; then
  icon="Green"
else
  icon="Alert"
fi

message=$(cat <<EOF
${icon} homefit publish health (24h)

- succeeded: ${succ_sum}
- failed (est): ${failed_sum}
- stuck > 10m: ${stuck_sum} across ${practices_stuck}/${practices_total} practice(s)
- last publish: ${max_ts}

Source: publish_health view (Milestone Q).
EOF
)

# ----------------------------------------------------------------
# 4. Send (or print, in --dry mode).
# ----------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  echo "------ DRY RUN — NOT POSTING ------"
  echo "$message"
  echo "-----------------------------------"
  exit 0
fi

# CallMeBot wants the message URL-encoded. Use jq's @uri filter to avoid
# a dependency on python3 / perl.
encoded=$(printf %s "$message" | jq -sRr @uri)

# Phone numbers must be in "+countryLocal" form for CallMeBot.
phone="${CALLMEBOT_PHONE}"
api_key="${CALLMEBOT_APIKEY}"

callmebot_url="https://api.callmebot.com/whatsapp.php?phone=${phone}&text=${encoded}&apikey=${api_key}"

http_code=$(curl -sS -o /tmp/callmebot.out -w '%{http_code}' "$callmebot_url")
if [[ "$http_code" != "200" ]]; then
  echo "CallMeBot returned HTTP ${http_code}:" >&2
  cat /tmp/callmebot.out >&2 || true
  exit 1
fi

echo "Ping sent (summary: $practices_total practices, ${stuck_sum} stuck, ${succ_sum} succeeded)"
