# Handover — Safe Mode embedding hotfix + Supabase Branching reconciliation

**Created:** 2026-05-23 by Claude. Context window getting full; Carl asked to hand off both remaining tasks to a fresh session.

**Status:** ready to dispatch. PR #455 is open with CI mid-flight at handover time; iPhone CHM has the previous `302c2d9 · staging` (profile) build with the avatar-resolve fix from PR #450 but NOT yet the bytea-encoding fix from #455.

## Table of contents

- [Task 1 — finish the Safe Mode embedding round-trip](#task-1--finish-the-safe-mode-embedding-round-trip)
- [Task 2 — Supabase Branching reconciliation](#task-2--supabase-branching-reconciliation)
- [Context — how we got here](#context--how-we-got-here)
- [Skills to use](#skills-to-use)
- [References](#references)

## Task 1 — finish the Safe Mode embedding round-trip

### 1.1 Background

The current Safe Mode v2 flow on the iPhone:
- Avatar resolves locally ✓ (PR #450).
- MobileFaceNet runs on-device + produces a 2048-byte embedding ✓.
- `setClientFaceEmbedding` RPC was 400'ing because `Uint8List` was being JSON-serialised as `[255,128,...]` → PostgreSQL cast that text representation to bytea → "got 7253 bytes" not 2048.

PR #455 ([github.com/carlheinmostert/TrainMe/pull/455](https://github.com/carlheinmostert/TrainMe/pull/455)) encodes the embedding as a `\x`-prefixed hex string before passing to the RPC, which is PostgREST's canonical bytea input format.

### 1.2 Steps

1. Confirm PR #455 is CI-green: `gh pr checks 455`. At handover time CI was UNSTABLE / pending; the Flutter iOS-build job + Supabase vault populate were still running. Expect a clean settle in <5 min from handover.
2. Merge: `gh pr merge 455 --squash --delete-branch`.
3. Rebuild + install via the new `homefit-install-device` skill in **profile mode** (debug crashes on launch on physical iPhone — see [gotcha_ios_debug_needs_debugger](../../memory/gotcha_ios_debug_needs_debugger.md)). This should be the FIRST warm build through the new skill — should land in 2-3 minutes (was ~10 min via the old `install-device.sh`). If it takes longer, that's a regression to investigate.
4. After install, Carl reopens the app, navigates to a client with `safe_mode_face_recognition = true` consent set, enters Camera mode, taps the "Prepare a face fingerprint" CTA on the Safe Mode v2 banner. Expected: brief "Preparing…" spinner, then capture-buttons re-enable. The embedding should now persist to `clients.face_embedding` (2048 bytes).
5. Verify via `mcp__supabase__execute_sql` against project `vadjvkmldtoeyspyoqbx`:
   ```sql
   SELECT name, length(face_embedding) AS bytes, face_embedding_model_version
   FROM clients WHERE id = '<the_client_id>';
   ```
   Should return `bytes = 2048`.
6. Once verified, write a brief device-QA test script under `docs/test-scripts/2026-05-23-safe-mode-embedding-roundtrip.md` and commit direct to main (per `feedback_specs_direct_to_main`). Numbered items: (1) embedding lands on server; (2) consent OFF zeros the embedding; (3) capture screen unblocks once embedding is ready.

### 1.3 Likely failure modes (and what to do)

- **PR #455 CI fails on the Flutter iOS-build job** — unrelated runner auth flake we've hit before (could not read Username for github.com). Retry the job, or merge if blocking checks pass.
- **Phone install hangs / errors** — kill any orphan `xcodebuild` and `install-device.sh` processes (today we had two stuck installers, fixed via `kill -9` then restart in the sticky worktree at `.claude/worktrees/iphone-install`).
- **Embedding STILL 400s after the fix** — diff the actual HTTP body sent vs. what the SQL function expects. Use `mcp__supabase__get_logs` against the staging project, `service: postgres`. The current diagnosis confidence is high (the hex format is PostgREST's documented bytea input shape) but if it fails, the next step is base64 encoding instead of hex.

## Task 2 — Supabase Branching reconciliation

### 2.1 Why this matters

The Supabase Branching workflow has been **silently skipping migrations on staging since at least 2026-05-22** because the `supabase_migrations.schema_migrations` table on the staging branch DB has duplicate rows — each migration is logged once with its **file timestamp** (from `supabase db push` / `supabase migration up`) and AGAIN with its **apply timestamp** (when applied via dashboard SQL editor or `mcp__supabase__apply_migration`). Same SQL content, different version stamps.

Future Branching pushes hit the CLI's drift detection (`Remote migration versions not found in local migrations directory`) and refuse to apply anything. The fallout today: PR #439 (Safe Mode v2 schema) and PR #448 (jsonb preserve) shipped to git but their migrations never reached the staging DB until I applied them via `mcp__supabase__apply_migration` as a recovery — which made the drift even worse.

### 2.2 The drift table

Sourced from this session's diagnostic. Confirm fresh via:

```sql
SELECT version, name, created_by
FROM supabase_migrations.schema_migrations
WHERE version LIKE '202605%'
ORDER BY version;
```

vs `git ls-tree origin/staging supabase/migrations/`.

| Local file timestamp | DB row timestamp | Migration name | Action |
|---|---|---|---|
| `20260522161500` | `20260523071454` | `safe_mode_transparency_phase_a` | rename DB row → local timestamp |
| `20260522162000` | `20260523071557` | `safe_mode_transparency_phase_b` | rename DB row → local timestamp |
| `20260522163000` | `20260523071650` | `safe_mode_transparency_phase_d` | rename DB row → local timestamp |
| (none — duplicate of 115754) | `20260522134110` | `create_default_premises` | DROP DB row (duplicate) |
| `20260523074049` | `20260523074636` | `fix_get_practice_profile_owner_srf` | rename DB row → local timestamp |
| `20260523085031` | `20260523100054` | `premises_public_slugs` | rename DB row → local timestamp |
| `20260523102954` | `20260523122942` | `safe_mode_v2` ↔ `safe_mode_v2_apply_recovery` | rename DB row → local timestamp |
| `20260523111633` | `20260523121234` | `live_view_logo_and_snapshot` | rename DB row → local timestamp |
| `20260523121727` | `20260523124541` | `revert_snapshot_infra` | rename DB row → local timestamp |
| `20260523130744` | `20260523132327` | `premises_safe_mode_toggle_audit` | rename DB row → local timestamp |
| `20260523140807` | `20260523123806` | `set_client_video_consent_preserve_safe_mode` ↔ `..._recovery` | rename DB row → local timestamp |

Three of these (the `safe_mode_v2`, the `set_client_video_consent_preserve_safe_mode`, and one extra `create_default_premises`) trace to MY apply-migration calls today — recovery work after diagnosing that the original PRs never landed. The fix is the same shape: rename so the version matches the canonical local file.

### 2.3 Plan

For each pair in the table:

1. Verify SQL equivalence — compare local file content against `supabase_migrations.schema_migrations.statements[1]` for the DB row. They should be substantively identical (allow for `BEGIN;`/`COMMIT;` wrapping differences and minor whitespace).
2. Apply the rename:
   ```sql
   UPDATE supabase_migrations.schema_migrations
      SET version = '<local_file_timestamp>'
    WHERE version = '<db_row_timestamp>'
      AND name = '<migration_name>';
   ```
   For the duplicate `create_default_premises` row at `20260522134110`, DROP the row (the SQL is also present at `20260522115754` which matches the local file).

3. After all renames, re-verify with the same diff query — local and remote should match 1:1.

4. Trigger a fresh Branching run: push an empty commit to staging (`git commit --allow-empty -m "chore: trigger Branching after migration reconciliation"`). Watch the `branch-action` logs via `mcp__supabase__get_logs` (service: `branch-action`) — the `Remote migration versions not found in local migrations directory` warning should be gone.

5. Check the staging branch status via `mcp__supabase__list_branches` — `status` should flip off `MIGRATIONS_FAILED`. Carl can also verify in the Supabase dashboard.

6. Lock in the protocol going forward — **migration files in git are the only source.** Add a memory entry (`feedback_supabase_branching_one_source.md`) documenting: never `supabase db push` and never apply via dashboard SQL editor or `mcp__supabase__apply_migration` while staging is healthy. The only acceptable path is: PR → merge to staging → Branching applies. Apply-migration is only for the recovery case when Branching is already broken, which should not be the normal path.

### 2.4 Risk

- **Updating `version` is a metadata-only change.** No data loss risk; if it goes wrong, restore from the value-was-X record (keep a SELECT snapshot before the UPDATE).
- **The "protected branch" log line** (`Skipping configuration for protected branch...`) seen in branch-action logs is a separate concern from the drift but doesn't actually block migrations — it only skips the auth-config / vault-secrets re-application step on a persistent branch. Confirm by re-reading the log after Task 2.3 reconciliation. If it still skips migrations, additional investigation needed.

## Context — how we got here

This session diagnosed and fixed three layered bugs in the Safe Mode v2 face-recognition flow:

1. **PR #445** — RPC param name (`p_allowed` → `p_consent`) in `setClientSafeModeConsent`. Red herring — the function didn't exist on staging.
2. **PR #448** — `set_client_video_consent` jsonb-preserve. Red herring — also never landed on staging.
3. **Recovery via `mcp__supabase__apply_migration`** — created today's drift rows.
4. **PR #450** — avatar-resolve path + `signClientAvatarUrl` param names (`bucket` → `p_bucket`). Real fix; landed and works.
5. **PR #455** — face-embedding bytea encoding. Real fix; pending CI / merge / install at handover time.

The full diagnostic loop is in this session's conversation. Key memory entries that came out:

- [feedback_no_silent_fallbacks](../../memory/feedback_no_silent_fallbacks.md) — `catch (e) { return false; }` in the API client is what hid all three of the above bugs. The next session should consider a follow-up PR to surface RPC failures visibly.
- [gotcha_ios_debug_needs_debugger](../../memory/gotcha_ios_debug_needs_debugger.md) — `flutter build ios --debug` produces a binary that white-screens on physical iPhone without `flutter run` attached.
- [feedback_long_agent_checkins](../../memory/feedback_long_agent_checkins.md) — updated to per-minute cadence when Carl is actively blocked.

A new skill landed: `homefit-install-device` at `/Users/chm/.claude/skills/homefit-install-device/SKILL.md` — sticky worktree + lazy deps + smart sync. Replaces calling `./install-device.sh` directly. Default mode is profile.

A new backlog entry landed at [docs/BACKLOG.md](../BACKLOG.md): "iPhone build-speed pass" with the three localised changes (debug-default — superseded; smarter fingerprint; conditional sync).

## Skills to use

- **`homefit-install-device`** — for rebuilding + installing PR #455 on the iPhone. Pass `profile` mode (debug builds white-screen on device).
- **`mcp__supabase__execute_sql`** — for verifying the embedding round-trip + reconciling the migration history.
- **`mcp__supabase__get_logs`** — for confirming the Branching action stops complaining after reconciliation.
- **`mcp__supabase__list_branches`** — for confirming `status` flips off `MIGRATIONS_FAILED`.
- **`homefit-add-memory`** — once reconciliation is done, capture the "one source of truth for migrations" rule.
- **`diagnose`** — only if anything goes sideways. Don't apply blindly.

## References

- PR #455: [github.com/carlheinmostert/TrainMe/pull/455](https://github.com/carlheinmostert/TrainMe/pull/455)
- Spec doc for Safe Mode v2: [docs/specs/2026-05-23-safe-mode-face-rec.md](../specs/2026-05-23-safe-mode-face-rec.md)
- Install-device skill: `/Users/chm/.claude/skills/homefit-install-device/SKILL.md`
- iPhone CHM UDID: `00008150-001A31D40E88401C`
- Staging Supabase project ref: `vadjvkmldtoeyspyoqbx`
- Prod Supabase project ref: `yrwcofhovrcydootivjx`
- Current iPhone build SHA at handover time: `302c2d9` (profile)
- Sticky build worktree: `.claude/worktrees/iphone-install`
