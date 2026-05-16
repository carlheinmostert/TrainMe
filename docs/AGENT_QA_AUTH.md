# Agent QA — Simulator Authentication Setup

Owner: Carl Mostert · Last updated: 2026-05-16

How Claude Code sub-agents sign into the iOS simulator without Carl's intervention. Two complementary mechanisms (persistent session + password-backed test account) cover the common QA loops.

## Table of Contents

- [Why this exists](#why-this-exists)
- [Two-mode overview](#two-mode-overview)
- [Mode A — Persistent session (preferred)](#mode-a--persistent-session-preferred)
- [Mode B — Password sign-in (fallback)](#mode-b--password-sign-in-fallback)
- [Reading `.env.test` from automation](#reading-envtest-from-automation)
- [Staging-only — how to verify](#staging-only--how-to-verify)
- [Rotating the QA password](#rotating-the-qa-password)
- [Granting additional credits](#granting-additional-credits)
- [Refreshing the persistent session](#refreshing-the-persistent-session)
- [Recreating the test user from scratch](#recreating-the-test-user-from-scratch)
- [What's deliberately out of scope](#whats-deliberately-out-of-scope)

## Why this exists

Today's `install-sim.sh` deliberately uninstalls the app on every run so Carl lands on a fresh Sign-In screen — perfect for brand screenshots, useless for autonomous agent QA. The two changes that unblock agent runs:

1. A sibling install script (`install-sim-keep-auth.sh`) that does NOT uninstall, preserving Supabase's Keychain-stored refresh token across rebuilds.
2. A dedicated test account on the STAGING Supabase project with credentials in a gitignored env file (`.env.test`) so agents can read the email + password when the persistent session lapses.

Together they cover the common case (rapid iteration on Studio / Clients UI) and the cold-start case (refresh token expired, full reinstall, etc.).

## Two-mode overview

| Mode | When session is fresh | When session lapsed |
|------|-----------------------|---------------------|
| A — Persistent session via `install-sim-keep-auth.sh` | Lands directly inside the app | Lands on Sign-In; fall through to Mode B |
| B — Password sign-in using `.env.test` | One-time bootstrap or after refresh-token expiry (~30 days) | Always works as long as the test account is alive |

Mode A is faster (no typing). Mode B is the seam that keeps Mode A working.

## Mode A — Persistent session (preferred)

```bash
./install-sim-keep-auth.sh                # ENV=branch (default)
./install-sim-keep-auth.sh staging        # pin to staging branch DB
```

The script mirrors `install-sim.sh` line-for-line EXCEPT it skips `xcrun simctl uninstall`. Keeping the bundle in place preserves the Keychain entries Supabase uses to persist the session.

Refresh-token lifetime is ~30 days. As long as the agent runs at least once every ~30 days, the session stays alive.

## Mode B — Password sign-in (fallback)

When the persistent session lapses (or the app gets manually uninstalled), the agent reads `.env.test`, gets the email + password, and drives the Sign-In screen via the `ios-simulator` MCP server.

```bash
# Example bash invocation (agents using `Bash` tool):
source .env.test
echo "$QA_TEST_EMAIL"
# qa@homefit.studio
```

The credentials in `.env.test`:

```
QA_TEST_EMAIL=qa@homefit.studio
QA_TEST_PASSWORD=<generated 24-char alphanumeric + safe-symbol mix>
QA_TEST_ENV=staging
QA_TEST_SUPABASE_PROJECT_REF=vadjvkmldtoeyspyoqbx
QA_TEST_PRACTICE_NAME=QA Test Practice
QA_TEST_PRACTICE_ID=f26a4870-727b-459f-abbe-71e10e38d755
QA_TEST_USER_ID=e8e0a4dd-1505-4ea7-82a2-cdfa67efc6c3
```

After a successful sign-in the Keychain entry is repopulated and Mode A works again for the next ~30 days.

## Reading `.env.test` from automation

Three common patterns, all assuming the working directory is the repo root.

**Bash:**

```bash
set -a
source .env.test
set +a
```

`set -a` exports every variable that the file defines, so subsequent processes inherit them.

**Python (`python-dotenv`):**

```python
from dotenv import dotenv_values
env = dotenv_values(".env.test")
email = env["QA_TEST_EMAIL"]
password = env["QA_TEST_PASSWORD"]
```

**Python (stdlib only):**

```python
from pathlib import Path
env = {}
for line in Path(".env.test").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    k, _, v = line.partition("=")
    env[k] = v
```

## Staging-only — how to verify

Any tooling that touches the QA credentials MUST confirm the environment is staging before doing anything. Two checks, both required:

1. `QA_TEST_ENV` in `.env.test` is the literal string `staging`.
2. `QA_TEST_SUPABASE_PROJECT_REF` equals `vadjvkmldtoeyspyoqbx` (staging) and does NOT equal `yrwcofhovrcydootivjx` (prod).

If either check fails, abort. Never use these credentials against prod.

The Supabase CLI confirms the mapping:

```bash
supabase branches list --project-ref yrwcofhovrcydootivjx --output json \
  | python3 -c "import sys,json; data=json.load(sys.stdin); print([b for b in data if b['name']=='staging'][0]['project_ref'])"
# vadjvkmldtoeyspyoqbx
```

## Rotating the QA password

Run from the repo root. Requires `supabase login` (the Supabase Personal Access Token must be in the macOS Keychain).

```bash
# Generate a new strong password (24 chars, no shell-quoting hazards).
NEW_PWD=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits + '!*-_+=.,:?@%^&'
while True:
    p = ''.join(secrets.choice(alphabet) for _ in range(24))
    if any(c.isupper() for c in p) and any(c.islower() for c in p) and any(c.isdigit() for c in p) and any(c in '!*-_+=.,:?@%^&' for c in p):
        print(p); break
")

# Look up the QA user id (or read QA_TEST_USER_ID from .env.test).
QA_USER_ID="e8e0a4dd-1505-4ea7-82a2-cdfa67efc6c3"
STAGING_REF="vadjvkmldtoeyspyoqbx"
SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref "$STAGING_REF" --output json \
  | python3 -c "import sys,json; ks=json.load(sys.stdin); print([k['api_key'] for k in ks if k.get('id')=='service_role'][0])")

# PATCH the user's password.
python3 <<PY
import json, urllib.request, os
payload = {"password": "${NEW_PWD}"}
req = urllib.request.Request(
    f"https://${STAGING_REF}.supabase.co/auth/v1/admin/users/${QA_USER_ID}",
    data=json.dumps(payload).encode(),
    headers={
        "apikey": "${SERVICE_ROLE_KEY}",
        "Authorization": f"Bearer ${SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    },
    method="PUT",
)
with urllib.request.urlopen(req) as resp:
    print("rotated OK:", json.loads(resp.read())["email"])
PY

# Update .env.test with the new password (manual sed or rewrite the file).
echo "Update QA_TEST_PASSWORD in .env.test to: $NEW_PWD"
```

After rotation, re-sign-in once in the simulator so the new password takes effect in Keychain.

## Granting additional credits

The QA practice starts with 8 credits (+3 signup_bonus, +5 adjustment). Top up via the Management API's database/query endpoint:

```bash
SUPABASE_PAT=$(security find-generic-password -s "Supabase CLI" -a "supabase" -w \
  | sed 's/^go-keyring-base64://' | base64 -d)
QA_PRACTICE_ID="f26a4870-727b-459f-abbe-71e10e38d755"
QA_USER_ID="e8e0a4dd-1505-4ea7-82a2-cdfa67efc6c3"

curl -sS -X POST "https://api.supabase.com/v1/projects/vadjvkmldtoeyspyoqbx/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg pid "$QA_PRACTICE_ID" --arg uid "$QA_USER_ID" '{
    query: "INSERT INTO public.credit_ledger (practice_id, delta, type, notes, trainer_id) VALUES (\($pid | @sql)::uuid, 10, '\''adjustment'\'', '\''agent QA top-up — staging only'\'', \($uid | @sql)::uuid) RETURNING practice_id, delta;"
  }')"
```

Adjust `delta` to taste. The `notes` field MUST mention "staging only" so the row is unambiguous in audit.

## Refreshing the persistent session

When `install-sim-keep-auth.sh` lands on the Sign-In screen (refresh token expired), the agent should:

1. Read `.env.test` for the email + password.
2. Use the `ios-simulator` MCP tools (`ui_find_element`, `ui_tap`, `ui_type`) to fill the email field, tap Continue, fill the password field, tap Sign In.
3. Wait for the Clients screen to render (or whatever the post-sign-in landing is at the time).
4. Subsequent `install-sim-keep-auth.sh` runs keep landing inside the app for ~30 days.

The agent-side automation that drives the sign-in flow is a separate follow-up task and is NOT part of this PR.

## Recreating the test user from scratch

If the test account is wiped (e.g. staging rebuild) and `.env.test` is stale, recreate it:

```bash
# 1. Generate a strong password.
QA_PWD=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits + '!*-_+=.,:?@%^&'
while True:
    p = ''.join(secrets.choice(alphabet) for _ in range(24))
    if any(c.isupper() for c in p) and any(c.islower() for c in p) and any(c.isdigit() for c in p) and any(c in '!*-_+=.,:?@%^&' for c in p):
        print(p); break
")

# 2. Fetch the staging service-role key.
STAGING_REF="vadjvkmldtoeyspyoqbx"
SERVICE_ROLE_KEY=$(supabase projects api-keys --project-ref "$STAGING_REF" --output json \
  | python3 -c "import sys,json; ks=json.load(sys.stdin); print([k['api_key'] for k in ks if k.get('id')=='service_role'][0])")

# 3. Create the user with email_confirm=true.
QA_USER_ID=$(python3 <<PY
import json, urllib.request
payload = {
    "email": "qa@homefit.studio",
    "password": "${QA_PWD}",
    "email_confirm": True,
    "user_metadata": {"is_qa_test_user": True, "notes": "Agent QA only — staging only."}
}
req = urllib.request.Request(
    "https://${STAGING_REF}.supabase.co/auth/v1/admin/users",
    data=json.dumps(payload).encode(),
    headers={"apikey": "${SERVICE_ROLE_KEY}", "Authorization": "Bearer ${SERVICE_ROLE_KEY}", "Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req) as resp:
    print(json.loads(resp.read())["id"])
PY
)
echo "QA user id: $QA_USER_ID"

# 4. Seed practice + member + signup_bonus + 5-credit adjustment via Management API SQL.
SUPABASE_PAT=$(security find-generic-password -s "Supabase CLI" -a "supabase" -w \
  | sed 's/^go-keyring-base64://' | base64 -d)

curl -sS -X POST "https://api.supabase.com/v1/projects/$STAGING_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg uid "$QA_USER_ID" '{
    query: "WITH np AS (INSERT INTO public.practices (name, owner_trainer_id) VALUES ('\''QA Test Practice — agent QA only'\'', \($uid | @sql)::uuid) RETURNING id), nm AS (INSERT INTO public.practice_members (practice_id, trainer_id, role) SELECT id, \($uid | @sql)::uuid, '\''owner'\'' FROM np RETURNING practice_id), nb AS (INSERT INTO public.credit_ledger (practice_id, delta, type, notes, trainer_id) SELECT id, 3, '\''signup_bonus'\'', '\''Organic signup bonus (agent QA seed)'\'', \($uid | @sql)::uuid FROM np RETURNING practice_id), ns AS (INSERT INTO public.credit_ledger (practice_id, delta, type, notes, trainer_id) SELECT id, 5, '\''adjustment'\'', '\''agent QA seed — staging only'\'', \($uid | @sql)::uuid FROM np RETURNING practice_id) SELECT (SELECT id FROM np) AS practice_id;"
  }')"

# 5. Write .env.test (the gitignored file the agent reads).
# Use the values printed above to fill QA_TEST_USER_ID and QA_TEST_PRACTICE_ID.
```

## What's deliberately out of scope

- **Magic-link automation via IMAP MCP.** A future task may automate the magic-link flow end to end (poll inbox, extract URL, deep-link into the app) but this PR sets up the simpler password path first.
- **Production account.** This setup is staging only by design. There is no QA test account on prod and there must not be.
- **Agent-side sign-in automation.** Driving the Sign-In screen via the `ios-simulator` MCP is a follow-up; this PR ships the static credentials + scripts.
- **Flutter app changes.** No app code touches required — `email + password` sign-in already exists per `app/lib/services/auth_service.dart`.
