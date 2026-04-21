# publish-health-ping

Wave 7 / Milestone Q — daily health summary for the publish pipeline.

Queries the `publish_health` SQL view (see
`supabase/schema_milestone_q_error_logs.sql`), summarises across the
fleet, and posts a one-liner to Carl's WhatsApp via CallMeBot.

## What it reports

For each practice visible to the service role:

* `succeeded_24h` — plan_issuances rows in the last 24 hours.
* `failed_24h` (estimate) — plans where the local version exceeds the
  number of issuance rows, in the last 24 hours. Proxy for "publish
  started, then failed mid-flight".
* `stuck_pending` — plans created > 10 minutes ago with no matching
  issuance row.
* `last_issued_ts` — most recent publish timestamp.

The message lands as a single WhatsApp bubble so it's safe to skim
first thing in the morning without opening the portal.

## One-time setup

```bash
cd tools/publish-health-ping
cp .env.example .env
# Fill in SUPABASE_SERVICE_KEY, CALLMEBOT_PHONE, CALLMEBOT_APIKEY
./ping.sh --dry    # verify the summary looks right locally
./ping.sh          # send a test ping
```

## Scheduling

Two options, activate whichever is most convenient:

### Option A — local cron on Carl's Mac (simplest)

```bash
crontab -e
# Daily 08:00 local time:
0 8 * * * cd /Users/chm/dev/TrainMe/tools/publish-health-ping && ./ping.sh
```

### Option B — Supabase scheduled edge function (production path)

Deferred. Wrap the logic inside a `supabase functions` edge function,
register via `supabase functions schedule`, and move the CallMeBot
credentials into the function's env. The edge function can also query
`publish_health` directly via PL/pgSQL instead of going over PostgREST.

File a follow-up when there's an active practice to alert about —
right now the signal is useful mostly for Carl's own QA.

## Dependencies

* `curl` — pre-installed on macOS.
* `jq` — `brew install jq` if not already present.

## Manual smoke test

```bash
./ping.sh --dry
```

Prints the composed message without hitting CallMeBot. Useful for
editing copy or debugging the jq summary logic.
