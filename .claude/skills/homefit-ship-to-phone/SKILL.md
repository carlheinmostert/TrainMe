---
name: homefit-ship-to-phone
description: Build the staging Flutter app, install on Carl's iPhone CHM, author a device-QA test script under docs/test-scripts/, and emit a numbered test list scoped to what changed in this wave. Use when Carl says "deploy to phone", "ship to iphone", "build + test list", "install for QA", or after a wave of merged PRs needs device verification.
---

# homefit-ship-to-phone

Ship the current `main` (or `staging`) build to Carl's iPhone CHM, author the matching device-QA test script, and hand Carl a tight numbered test list. Encodes the always-test-script, numbered-list, open-via-localhost, golden-path-smoke, and demote-old-waves rules.

## Inputs

- Wave slug or PR list. **Default discovery mechanism:** query merged PRs labelled `ios-impact` since the last device install. CI auto-applies the label to any PR whose diff touches Dart / Swift / pubspec / podfile / privacy manifest (i.e. `app/**` excluding the web-player mirror at `app/assets/web-player/**`). Only ask Carl explicitly if the label query returns nothing AND recent commits don't make the wave obvious.
- The build channel — default `staging` unless Carl says prod.
- iPhone CHM UDID: `00008150-001A31D40E88401C`.

## Workflow

### 0. Assemble the wave (preferred path)

Run the wrapper:

```bash
./tools/ios-pending-prs.sh                 # last 2 days (default)
./tools/ios-pending-prs.sh 7d              # last week
./tools/ios-pending-prs.sh 2026-05-23      # since explicit date
```

That returns the merged-and-labelled PRs with title, branch, merge time, URL. Use this as the "wave" — those are the PRs the device install covers.

If the list is empty, fall back to `git log --since=<last_install_date>` to manually classify; if even that's empty, ask Carl what wave he meant.

The `ios-impact` label is purely additive (sticky regardless of install state) — no auto-removal happens after install. If post-install noise becomes a problem we'll add a `--since-last-install` marker later.

### 1. Decide whether to run the simulator smoke check first

Classify the change since the last device install (`git log --since=<last_install_date>` and `git diff --stat`):

- **Run simulator smoke first** if the diff touches any of:
  - `supabase/migrations/**` or any `CREATE OR REPLACE FUNCTION`
  - `app/lib/services/api_client.dart`, `auth_service.dart`, `upload_service.dart`, `sync_service.dart`
  - RLS, RPC signatures, SECURITY DEFINER bodies
  - Session-refresh / SyncService pull-branch logic
  - Multi-file architectural rewrites (AppBar, navigation, PageView shells)
- **Skip simulator smoke** if the diff is:
  - Pure cosmetic single-file widget tweaks (font, color, spacing, copy)
  - Round 2/3 of a visual change Carl just rejected
  - Test-script-only edits

If smoke needed, run `./install-sim.sh` in background and walk the three golden paths:
  1. Client list renders (avatars where present).
  2. Open an exercise → edit reps/sets/hold/notes → leave Studio → return → edit persists.
  3. Photo capture as last exercise → conversion spinner clears in-place inside 1.5s.

If any of the three fails, surface immediately and STOP. Do not progress to device install.

### 2. Install on device

**Delegate to the `homefit-install-device` skill.** It asks Carl debug-vs-profile (default debug), uses the sticky `.claude/worktrees/iphone-install` source tree so Xcode DerivedData survives across builds, and `xcrun devicectl` installs to the iPhone CHM.

Do NOT call `./install-device.sh` directly — its per-call worktree churn was the dominant slowness cause. The skill bypasses it.

Capture the SHA the install skill reports back; feed it into the test-script kicker and the final message lead-in.

### 3. Author the device-QA test script

Path: `docs/test-scripts/<YYYY-MM-DD>-<slug>.md` — **plain Markdown** (as of 2026-05-21). Structure:

- H1 title: `# <Wave name> — device QA (YYYY-MM-DD)`
- One short paragraph block: branch, PR link, build SHA, scope ("what changed", "what did NOT change", any sections being skipped).
- One `## ` H2 per logical group (lettered: `## B. Portal — …`, `## E. Mobile — …`, etc. — pick up lettering from any prior wave being continued).
- Items as GitHub-style checkbox bullets: `- [ ] N. Description.` — numbering is FLAT (1..N across the whole wave), STABLE (never re-number mid-wave, never re-number when items pass).
- 3 to 12 items per group. Group similar checks together.
- If some items are KNOWN to fail (deliberate gap, missing follow-up wave), put them under `## G. Known gaps — should FAIL (confirm failure mode)`.
- No HTML, no inline scripts, no POSTs, no `<style>` blocks. Just Markdown.

### 4. Update the index

`docs/test-scripts/index.md` (Markdown). Add the new wave under `## Active wave` at the top. Move any wave this build supersedes to `## Past waves`. If only the legacy `index.html` still exists, create `index.md` alongside.

### 5. (No server step)

The localhost server pattern is RETIRED. Carl opens the .md in the Claude Code Desktop preview pane (`Cmd+Shift+V`) and gives pass/fail feedback in the terminal.

### 6. Compose the final message

End the reply with:

1. **One-line install confirmation** including the build SHA, e.g. `Installed on iPhone CHM (SHA abc1234).`
2. **The list of PRs the install covers** (from step 0). Format: `Covers N PRs: #123, #124, #125 (titles + branches inline if there's room)`. This is the audit trail — Carl can scan it to confirm the wave matches what he expected.
3. **Link to the test script** as a Markdown link to the file path: `[docs/test-scripts/<YYYY-MM-DD>-<slug>.md](docs/test-scripts/<YYYY-MM-DD>-<slug>.md)`. Remind him `Cmd+Shift+V` opens the preview pane.
4. **A 3-7 item numbered test list inline** scoped to what changed this wave (mirrors the most important items from the .md). Each item names the screen, the gesture, and the expected result so Carl can reply `1 ✓, 2 broken at step 3`. Stable numbers — do not reorder mid-session.

### 7. WhatsApp ping

Invoke `anthropic-skills:send-whatsapp` to notify Carl the build is on his phone with the SHA. Keep it one line.

## Don'ts

- Don't author test scripts as HTML. Markdown only.
- Don't start `_server.py` or reference `http://localhost:3457/`. That stack is retired.
- Don't auto-commit / auto-push / auto-merge. Carl confirms in chat.
- Don't append new wave items into an already-open wave file mid-session. New requirements go into the NEXT wave script.
- Don't mutate the .md mid-wave to record pass/fail. State lives in chat; the .md is the spec.

## Encodes

- `feedback_always_test_script`
- `feedback_numbered_test_list`
- `feedback_test_scripts_open_in_safari`
- `feedback_golden_path_smoke_before_install`
- `feedback_test_scripts_move_to_past`
- `feedback_no_preview_mentions`
- `feedback_test_wave_discipline`
- `feedback_test_scripts_unicode`
- `ios-impact` PR label workflow (2026-05-23) — CI in `.github/workflows/ci.yml` auto-labels any PR whose diff touches real Dart / Swift / pubspec / podfile / privacy manifest. Wrapper at `tools/ios-pending-prs.sh` queries the labelled merged PRs as the discovery mechanism for wave assembly. Supports multi-Claude-session workflows where parallel sessions open PRs and one session does the consolidated install.
