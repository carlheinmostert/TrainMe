---
name: homefit-agent-brief
description: Compose a clean sub-agent brief for the homefit.studio repo that encodes the standard conventions — repo-relative paths only, R-10 mobile/web parity rule if touching the player, no direct DB access (RPCs only), target branch `staging` not `main`, branch naming with `fix/`/`feat/`/`chore/`/`docs/` prefix, no emojis. Use when Carl says "spawn agent for X", "delegate X to a sub-agent", "send X to an agent", "agent brief for X", or any request to hand off multi-file coding work to a background sub-agent. Encodes feedback_agent_worktree_isolation, feedback_no_direct_db_access, feedback_branch_naming_discipline, feedback_delegate_coding, and the R-10 mobile/web parity rule.
---

# homefit-agent-brief

## Purpose

Sub-agents drift when their briefs leak absolute paths, omit the staging/main discipline, or skip the R-10 parity rule. This skill produces a brief that's clean by construction, validated for absolute-path leaks before handoff, and tagged with the right sub-agent type.

## When to invoke

- Carl says "spawn an agent for X", "delegate X", "send X to a sub-agent", "agent brief for ..."
- Multi-file coding work surfaces that would bloat the main conversation (per `feedback_delegate_coding.md`)
- Carl says "just do X" and X is plainly multi-file (offer to delegate first, per the same rule)

## Workflow

### Step 1: Capture the task envelope

Ask (one short message, batch the questions):
1. **What** — concise task description
2. **Where** — which files / surfaces (mobile / web-player / web-portal / supabase / docs)
3. **Branch name** — propose `<prefix>/<short-noun>` per `feedback_branch_naming_discipline.md`, ask Carl to confirm or override
4. **PR context** — is there an existing PR to extend, an issue to close, prior wave to mirror?

For docs-only work, branches are not used — skip naming and confirm Carl wants direct-to-main per `feedback_specs_direct_to_main.md`.

### Step 2: Determine surface(s) and which constraints to inject

Surface table:

| If task touches | Inject these constraints |
|---|---|
| `app/lib/` (Flutter) AND `web-player/` | R-10 parity rule (both surfaces in same PR) |
| `app/lib/` only AND it changes player UI | R-10 parity rule — remind to mirror to web-player |
| `web-player/` only AND it changes player UI | R-10 parity rule — remind to mirror to mobile preview |
| `supabase/migrations/` or SECURITY DEFINER fns | No-direct-DB rule + RPC-only rule + `pg_get_functiondef` pre-flight (per `feedback_schema_migration_column_preservation.md`) |
| `web-portal/src/` | RPC-only via `web-portal/src/lib/supabase/api.ts` |
| `docs/test-scripts/*.html` | Test-script unicode rule, server-URL not file://, pass/fail buttons |
| Anything tappable on iOS | Reader-app rule (no PayFast / no buy buttons / no tappable purchase paths) |
| Anything email-related | Resend SMTP relay; check `docs/RESEND_SETUP.md` |

### Step 3: Compose the brief

Use this exact template (markdown, headings):

```markdown
# Task: <one-line summary>

## Context
<2-4 sentences: what's broken / what to build. Reference relevant prior PRs, checkpoints, or memory rules by file path. Use REPO-RELATIVE paths — `docs/CHECKPOINT_*.md`, `app/lib/foo.dart`, `supabase/migrations/*.sql`.>

## Constraints (HARD RULES — read first)
- Use REPO-RELATIVE paths only in your tool calls. Never absolute `/Users/chm/dev/TrainMe/...` paths. A PreToolUse hook at `.claude/hooks/rewrite-agent-prompts.py` strips them, but write clean briefs anyway.
- No emojis in code, comments, commit messages, or PR bodies.
<INJECT IF SUPABASE WORK>
- All DB reads/writes go through the per-surface access layer (`app/lib/services/api_client.dart` / `web-portal/src/lib/supabase/api.ts` / `web-player/api.js`) which routes through enumerated SECURITY DEFINER RPCs. NEVER direct table SELECT/INSERT/UPDATE/DELETE from client code. See `feedback_no_direct_db_access.md`.
- Before any `CREATE OR REPLACE FUNCTION`, source the current definition from live DB via `pg_get_functiondef`, NOT from `supabase/*.sql` files (they lag). See `feedback_schema_migration_column_preservation.md`.
</INJECT>
<INJECT IF PLAYER WORK>
- R-10 parity: any change to player UX must land on BOTH the Flutter player (`app/lib/screens/plan_preview_screen.dart`, `app/lib/widgets/progress_pill_matrix.dart`) AND the web player (`web-player/app.js`, `web-player/styles.css`, `web-player/lobby.js`) in the SAME PR. Implement on mobile first (faster iteration), verify on simulator, mirror to web in same branch.
</INJECT>
<INJECT IF CODE PR>
- Branch: `<branch-name>` — already created or to be created off `staging`.
- PR target: `staging` (NOT `main`). Carl explicitly promotes staging → main when the bundle is ready.
</INJECT>
<INJECT IF iOS UI>
- iOS Reader-App rule: no in-app purchase paths. No buy buttons, no tappable `manage.homefit.studio` for purchase, no PayFast mentions in copy. Plain-text at zero-balance state. See `feedback_ios_reader_app.md`.
</INJECT>

## Acceptance criteria
1. <Testable bullet>
2. <Testable bullet>
3. <Testable bullet>

## Deliverable
- PR title format: `<feat|fix|chore>: <imperative summary>`
- PR body sections: **What changed**, **Why**, **How to test**, **Risk**
<INJECT IF VISUAL CHANGE>
- Include before/after screenshots in PR body (simulator screenshots for mobile; localhost screenshots for web).
</INJECT>
- Commit message style: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`). No emojis.

## Files likely to change
- <repo-relative path 1>
- <repo-relative path 2>

## Out of scope
- <anything explicitly NOT being touched, to prevent scope creep>
```

### Step 4: Validate the brief

Run this check on the composed brief string before showing it to Carl:

```sh
echo "$BRIEF" | grep -E '/Users/chm/dev/TrainMe' && echo "FAIL: absolute path in brief" || echo "OK: no absolute paths"
```

If any absolute paths slip in, rewrite them to repo-relative form. Common offenders:
- `/Users/chm/dev/TrainMe/app/lib/...` → `app/lib/...`
- `/Users/chm/dev/TrainMe/docs/...` → `docs/...`
- `/Users/chm/dev/TrainMe/CLAUDE.md` → `CLAUDE.md`

The memory folder path (`/Users/chm/.claude/projects/...`) is fine — it's outside the repo and the hook only strips the repo prefix.

### Step 5: Suggest sub-agent type

| Task shape | Sub-agent type |
|---|---|
| UI / React / web player / Flutter widgets / CSS | `frontend-architect` |
| Supabase RPCs / Edge Functions / migrations / RLS | `backend-architect` |
| Build tooling / Python scripts / `tools/` | `python-expert` |
| Test scaffolding / QA infra | `quality-engineer` |
| Dead-code sweep / refactor / rename | `refactoring-expert` |
| Cross-cutting research / multi-surface audit | `general-purpose` |
| Documentation / spec drafting | `general-purpose` (docs only, no code) |

### Step 6: Present to Carl for review

Show the brief verbatim plus:
- Branch name
- Sub-agent type recommendation
- `isolation: "worktree"` (default for any multi-file work — non-negotiable per `feedback_agent_worktree_isolation.md`)
- `run_in_background: true` unless Carl needs the result inline

Wait for Carl's go-ahead. Per `feedback_new_reqs_new_threads.md`, if Carl introduces a new requirement, queue it as a follow-up brief — don't interrupt the running agent.

### Step 7: On go-ahead, spawn

Spawn the Agent tool with:
- `isolation: "worktree"`
- `run_in_background: true` (default)
- The composed brief as the prompt
- The sub-agent type Carl approved

Confirm to Carl with the agent's worktree path and how to monitor (or that he'll be notified on completion).

## Standard constraint snippets (copy-paste verbatim)

For convenience, here are the exact strings to paste into briefs when the surface matches:

### Repo-relative paths (always include)
```
Use REPO-RELATIVE paths only in your tool calls. Never absolute `/Users/chm/dev/TrainMe/...` paths. A PreToolUse hook at `.claude/hooks/rewrite-agent-prompts.py` strips them, but write clean briefs anyway.
```

### No direct DB (Supabase work)
```
All DB reads/writes go through the per-surface access layer which routes through enumerated SECURITY DEFINER RPCs. NEVER direct table SELECT/INSERT/UPDATE/DELETE from client code:
- Flutter: `app/lib/services/api_client.dart`
- Web portal: `web-portal/src/lib/supabase/api.ts`
- Web player: `web-player/api.js` (anon `get_plan_full` only)
See `feedback_no_direct_db_access.md`.
```

### R-10 parity (player work)
```
R-10 parity rule: any player UX change lands on BOTH surfaces in the SAME PR:
- Flutter player: `app/lib/screens/plan_preview_screen.dart`, `app/lib/widgets/progress_pill_matrix.dart`
- Web player: `web-player/app.js`, `web-player/styles.css`, `web-player/lobby.js`
Implement on mobile first, verify on simulator, mirror to web in same branch.
```

### Target staging (code PR)
```
Branch: `<name>` off `staging`.
PR target: `staging` (NOT `main`). Carl promotes staging → main explicitly when bundle is ready.
```

### No emojis
```
No emojis anywhere — code, comments, commit messages, PR bodies, file names.
```

## Anti-patterns to refuse

- Spawning an agent without `isolation: "worktree"` when the task touches more than one file
- Briefs that quote absolute `/Users/chm/dev/TrainMe/...` paths
- Briefs that say "make a PR against main" — always staging for code
- Skipping the R-10 parity reminder on player work (cost 4 PRs to re-learn per `feedback_mobile_preview_local_only.md`)
- Briefs that include `psql` / direct table queries instead of RPC calls
- Pasting decorative emojis into the brief itself ("Build the X feature ✨")
