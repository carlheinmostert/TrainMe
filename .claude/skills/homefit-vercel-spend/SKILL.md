---
name: homefit-vercel-spend
description: Pull month-to-date Vercel spend for the homefit projects (homefit-web-portal and homefit-web-player under team carlheinmosterts-projects), compare against the previous snapshot, flag spikes (>30% jump or >$20 absolute) and quota approaches (>80% of Pro-tier included quotas), then append today's snapshot to ~/.claude/projects/-Users-chm-dev-TrainMe/vercel-spend-snapshots.jsonl. Use when Carl says "vercel spend", "check vercel spend", "how much have we spent", "vercel bill", "vercel usage", or auto-run after a web deploy completes (per feedback_vercel_spend_monitor). Carl is on Vercel Pro since 2026-04-20; report plain-English summary not rate tables (per feedback_explanation_level).
---

# homefit-vercel-spend

## Purpose

After every Vercel-deploy-triggering action, Carl wants visibility into spend before it surprises him on the next bill. He's on Pro since 2026-04-20 (uncapped). This skill is the one-stop spend check: pull, compare, flag, snapshot, report — concisely.

## When to invoke

- Carl says any of: "vercel spend", "check spend", "how much have we spent", "vercel bill", "vercel usage", "what are we spending"
- Auto-run after a merge to `main` that touches `web-portal/` or `web-player/` (per `feedback_vercel_spend_monitor.md`)
- Auto-run after `vercel deploy` or a direct push to `main` with web changes

Do NOT invoke for mobile-only deploys (`./install-device.sh` doesn't touch Vercel).

## Constants

- Team: `carlheinmosterts-projects`
- Projects:
  - `homefit-web-portal` (Next.js, manage.homefit.studio)
  - `homefit-web-player` (static, session.homefit.studio) — verify slug with `vercel ls` if first run
- Snapshot file: `/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/vercel-spend-snapshots.jsonl` (create if absent)
- Carl's plan: Vercel Pro (since 2026-04-20)

### Pro-tier included quotas (flag if > 80%)

- Bandwidth: 1 TB/month
- Edge requests: 1M/month
- Build minutes: 6000/month
- Fluid Compute: 100 GB-hours/month
- Fast Data Transfer: confirm in dashboard

## Workflow

### Step 1: Verify auth

```sh
vercel ls --token "${VERCEL_TOKEN:-}" 2>&1 | head -5
```

If output contains "Error: You need to be logged in" or similar:

> Vercel CLI isn't authenticated. Run `vercel login` and re-invoke. If `vercel login` is already done in another shell, the CLI uses `~/.local/share/com.vercel.cli/auth.json` — try `vercel whoami` to confirm.

Bail until Carl authenticates.

### Step 2: Pull MTD spend

The Vercel CLI doesn't expose a direct `billing` subcommand for MTD numbers, but `vercel inspect` and the Vercel API can. Use this order:

1. Try the Vercel API directly:
   ```sh
   TEAM_ID=$(vercel teams ls --json 2>/dev/null | jq -r '.teams[] | select(.slug=="carlheinmosterts-projects") | .id')
   curl -s "https://api.vercel.com/v1/teams/$TEAM_ID/billing/usage?period=current" \
     -H "Authorization: Bearer $(cat ~/.local/share/com.vercel.cli/auth.json | jq -r .token)" \
     -H "Content-Type: application/json"
   ```
   Parse the JSON for: `total` (USD), `bandwidth.gb`, `edgeRequests.count`, `buildExecution.minutes`, `fluid.gbHours`.

2. If the API call fails (auth, schema drift, rate limit), fall back to the dashboard:
   - URL: `https://vercel.com/carlheinmosterts-projects/~/usage` and `https://vercel.com/teams/carlheinmosterts-projects/settings/billing`
   - Tell Carl: "API didn't return usage — please open the billing dashboard and paste the current MTD numbers (total $, bandwidth, edge requests, build minutes)." Then proceed with the values he pastes.

3. Per-project numbers: `vercel inspect <deployment-url>` shows build duration and bandwidth for a specific deployment but not MTD per project. The team-level total is the primary metric; project-level only matters when flagging which project drove a spike (use `vercel ls --json | jq` to count recent deploys per project as a proxy).

### Step 3: Compare against last snapshot

Read the last line of `~/.claude/projects/-Users-chm-dev-TrainMe/vercel-spend-snapshots.jsonl`:

```sh
SNAP=/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/vercel-spend-snapshots.jsonl
[ -f "$SNAP" ] && tail -n 1 "$SNAP" || echo "{}"
```

Each line is JSON like:
```json
{"date": "2026-05-15T10:30:00Z", "mtd_usd": 12.40, "bandwidth_gb": 45.2, "edge_requests": 230000, "build_minutes": 180, "fluid_gb_hours": 2.1, "fast_data_transfer_gb": 8.3}
```

Compute deltas:
- `delta_usd = current.mtd_usd - last.mtd_usd`
- `delta_pct = delta_usd / max(last.mtd_usd, 0.01) * 100`
- For each quota: `quota_pct = current.<key> / <pro_limit> * 100`

### Step 4: Flag if any of these are true

- `delta_pct > 30%` AND `delta_usd > 5` (the second condition prevents nuisance flags on tiny absolute deltas)
- `delta_usd > 20` absolute (regardless of percentage)
- Any quota > 80% of its Pro limit
- The day-of-month-adjusted projection: `mtd_usd / day_of_month * 30` is more than 50% above last full month's spend (loose projection — only flag if data is available)

### Step 5: Append snapshot

```sh
SNAP=/Users/chm/.claude/projects/-Users-chm-dev-TrainMe/vercel-spend-snapshots.jsonl
mkdir -p "$(dirname "$SNAP")"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "{\"date\":\"$NOW\",\"mtd_usd\":<n>,\"bandwidth_gb\":<n>,\"edge_requests\":<n>,\"build_minutes\":<n>,\"fluid_gb_hours\":<n>,\"fast_data_transfer_gb\":<n>}" >> "$SNAP"
```

Use the Write tool to append rather than echoing if any value might contain quotes, but for pure numbers a one-line echo is fine.

### Step 6: Report

Per `feedback_explanation_level.md`, plain-English not rate tables. Template:

> **Vercel MTD: $X.XX** — up $Y.YY since last check (Δ Z%).
> Bandwidth: A GB of 1 TB (B%). Edge requests: C of 1M (D%). Build minutes: E of 6000 (F%).
> [Flag line only if Step 4 triggered, e.g. "Bandwidth at 82% — consider checking what's driving it." or "Spike: build minutes up 4x today; recent deploy spam suggests a runaway loop."]

If no flag triggered, end with: "Healthy. Next check on next deploy."

If a flag triggered, end with: "Investigate before next deploy." and surface the most likely cause (which project recently deployed most? which quota approached its limit?).

## Failure modes

### Vercel CLI not installed
Report: "vercel CLI not on PATH. Install with `brew install vercel-cli` then re-invoke."

### Snapshot file corruption
If the JSONL has malformed lines (`jq` fails), don't truncate it. Tell Carl, skip the comparison, just snapshot the current values and report current MTD.

### Project slug mismatch
If `homefit-web-player` returns 404 from `vercel inspect`, try alternatives: `train-me`, `homefit-player`, `web-player`. The brief mentioned `train-me` as a legacy slug — verify with `vercel ls --json | jq '.deployments[].name' | sort -u | head` and update this skill's constants once confirmed.

### Rate limit
Vercel API has a per-team rate limit. If hit, wait 60s and retry once. If it fails again, fall back to the dashboard prompt.

## Anti-patterns

- Reporting raw JSON or a rate table — Carl wants plain-English (per `feedback_explanation_level.md`)
- Blocking a deploy on spend — this is report-after-the-fact, not a gate
- Skipping the snapshot append when the comparison failed — still record the current numbers for next time
- Asking Carl to log in via dashboard if the CLI is authenticated — try the CLI first
- Including dollar amounts to four decimal places — round to cents

## Related rules encoded

- `feedback_vercel_spend_monitor.md` — the underlying mandate
- `feedback_explanation_level.md` — plain-English reporting
- `feedback_use_apis_not_dashboards.md` — prefer CLI/API over the dashboard
