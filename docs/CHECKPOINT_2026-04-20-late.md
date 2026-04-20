# Session Handoff — 2026-04-20 late-session (post-marathon)

> **Hi future Claude.** This is the second handoff for 2026-04-20 — an
> additional ~10-hour marathon after [`CHECKPOINT_2026-04-20.md`](CHECKPOINT_2026-04-20.md)
> was already written for the "end of day." Read BOTH docs in order.
>
> Carl likely says "where were we?" when he starts the new session.
> Give him a tight summary from this doc.

## One-sentence status

**Huge marathon — everything in Wave 3 landed + QA'd + archived; Waves
4–9 are spec'd and queued; Wave 6 Phase 1 shipped; Wave 4 Phase 1 +
Wave 5 Members work + Q2 card-UI batch are queued but their first agent
spawns died silently mid-flight and need re-spawning from a fresh
session with the new worktree-isolation hook active.**

## What landed today (post-CHECKPOINT_2026-04-20.md baseline)

**Wave 3 PRs (all merged):**
- #43 — Pending chip visible offline
- #44 — Client consent chip relabel + sheet restructure + copy-icon removal
- #45 — Home logo lockup at top + SHA marker relocated to Settings
- #46 — Studio cleanup: remove PracticeChip, ViewingPrefsButton, MediaViewer consent row
- #47 — Studio exercise card overhaul (Muted, custom duration, dividers, coral perimeter, long-press fix)
- #48 — Mute decouple + per-exercise prep countdown (SQLite v19, supabase schema migration `schema_milestone_p_prep_seconds.sql`)
- #49 — Test-scripts landing page (single bookmarkable entry at `http://localhost:3457/test-scripts/` with live pass/fail tallies via `/test-scripts/<slug>.json` static path; `/api/test-results/` is POST-only)
- #58 — Wave 3 minor rats-and-mice: long-press z-order (size-interpolated builder), prep-seconds Done button, Home padding 3×, consent pill removed from Home list, **no popup on new client** (auto-names `New client N` → drops into detail → inline rename)
- #60 — Wave 3 moved from active-card → archive on the landing page

**Preview / mobile architecture stabilisation:**
- #50, #51, #52 — iterative attempts to unblock B&W/Original playback (local archive, HEAD probe, null-URL fallback)
- **#53 (big one) — Mobile preview is LOCAL-ONLY**: `_controllerForTreatment` uses `VideoPlayerController.file` for all three treatments. Net −70 lines; retires all the HEAD-probe / remote-fallback complexity from #50/#51/#52. New rule memorialised in `memory/feedback_mobile_preview_local_only.md`.
- #56 — **Web player per-slide treatment**: dropped the client-facing Line/B&W/Original picker. Treatment comes from `exercise.preferred_treatment`. Aligns with mobile's "no viewer-driven switching."

**Cloud B&W/Original debug (4-hour session):**
- #54 — `upload_service.dart` now calls `upsert_client` + passes `client_id` on publish + blocks publish until archive compression ready
- #55 — raw-archive upload uses `upsert: false` + explicit `contentType: 'video/mp4'` (the upsert:true against a bucket with no SELECT policy was silently failing every upload across ALL practices since the feature shipped). Also — `install-device.sh` switched from `--release` to `--profile` so `debugPrint` survives for QA. Breadcrumb log added at `{Documents}/raw_archive_error.log`.
- **Vault secret manually populated** — `supabase_jwt_secret` in the vault was the literal placeholder `<HS256-signing-key>`. Carl ran `vault.update_secret(...)` in his terminal with the real legacy JWT secret. NOT version-controlled (it's in the vault now). **Tech debt:** `sign_storage_url` pgjwt approach needs replacement with Supabase's native signed-URL endpoint via Edge Function — see `docs/BACKLOG.md`.

**iPhone Q1 polish batch (PRs #64/#66/#67/#68):**
- #64 — 3-state publish indicator (`lastContentEditAt` column, SQLite v20) + insert-dot haptic on touch-down + camera "Hold for video" hint + Settings "Top up credits" link to portal
- #66 — Q1 Bug fix: `_touchAndPush` now persists to SQLite (wasn't before — stamp was in-memory only, reload wiped it); haptic bumped from `selectionClick` → `lightImpact`
- #68 — Insert-dot haptic FINAL fix: wired `Listener.onPointerDown` + `mediumImpact` on the ACTUAL Studio-screen insert widget (earlier fixes patched `GutterGapCell` in `gutter_rail.dart`, which turns out NOT to be the widget the Studio renders — Studio has its own inline GestureDetector). Root cause lesson: verify the widget path before shipping a haptic fix.
- Carl confirmed: 3-state publish + insert-dot haptic both PASS on device.

**Portal R-11 catch-up (mobile↔portal parity):**
- #61 — Dropped `ConsentChip` mini-pills from `/clients` list (mobile Home removed these; portal was drifting)
- #62 — `/clients/[id]` consent UI gets a `VIDEO TREATMENT` section header + extension-point comment (mirroring mobile's grouped sheet layout). Also added TODO stub on `SessionsList.tsx` for future 3-state publish indicator parity.
- **NOT done:** add-client flow on portal — no affordance exists today (mobile-only). Needs new `upsertClient` wrapper on `PortalApi` + button + navigation. Queued.

**Wave 6 Phase 1 (PR #63 — merged):**
- `/network` portal page rewritten with three rendered share templates (WhatsApp 1:1, WhatsApp broadcast, Email) + copy-to-clipboard buttons + OG unfurl previews + PNG/QR placeholder slot. Auto-fills practitioner name + referral link + practice name. Vercel auto-deployed.
- **Not done (Phase 2/3):** `wa.me` / `mailto:` intent launchers, PNG share-card generation, QR codes.

**Infrastructure (PR #65):**
- `.claude/hooks/rewrite-agent-prompts.py` + `.claude/settings.json` — `PreToolUse` hook that strips `/Users/chm/dev/TrainMe/` absolute paths from Agent prompts when `isolation: worktree` is set, and prepends a CRITICAL worktree-isolation banner. Would have prevented today's "agent writes leaked to main" saga.
- `.gitignore` carved out to let `.claude/settings.json` + `.claude/hooks/**` travel via git.
- **Activation caveat:** Claude Code's settings watcher only picks up `.claude/settings.json` in sessions where it was present at session START. Today's session didn't have it, so the hook is inactive here. **A fresh session should pick it up automatically.**

**Docs / roadmap (#57, #59):**
- `docs/design-reviews/silent-failures-2026-04-20.md` — full design review for observability (error_logs, _loudSwallow, boot self-check, publish_health cron). Scheduled as Wave 7.
- `docs/BACKLOG.md` — full specs for Waves 4–9 at the top.

## Active / in-flight work needing resume

### Dead agents that need re-spawn (from fresh session with hook active)

- **Wave 4 Phase 1 — Unified player prototype**
  - Scope: bundle `web-player/` into `app/assets/`, serve via in-process Dart `shelf` HTTP server, load in `webview_flutter`, substitute local file URLs at `/local/<exerciseId>/{line,archive}`, add localhost branch to `web-player/api.js`.
  - First agent died silently (127 bytes, no work).
  - Retry agent ALSO died silently (127 bytes, no work).
  - Fresh session + hook active should break the cycle.
  - Full brief template in the prior agent history — safe to re-use verbatim.

- **iPhone Q2 batch — Studio card rep duration + set rest**
  - Scope: `SET REST` slider after Hold (new `setRestSeconds` column, SQLite + Supabase migration); `REP DURATION` single-line pill selector `[Video Ns] [Custom Ns]` replacing the `Use video length as 1 rep` toggle + custom duration row; new per-rep `repDurationSeconds` column (replaces the TOTAL-based `customDurationSeconds`, lazy migration on read).
  - First agent died silently. Retry died silently. Needs fresh session.
  - Brief finalised + ASCII-art confirmed with Carl. Template ready.

### Queued work (not yet spawned)

- **Wave 5 Members area** (specced in BACKLOG)
  - 4 new RPCs: `list_practice_members_with_profile`, `mint_practice_invite_code`, `claim_practice_invite`, `set_practice_member_role`, `remove_practice_member`, `leave_practice`
  - New table: `practice_invite_codes(code PK, practice_id, created_by, created_at, claimed_by, claimed_at, revoked_at)`
  - Portal: `/members` rewrite + `/join/:code` landing page
  - **Decisions locked:** per-practitioner-per-practice codes, no expiry, auto-join on claim, owner-only mint.

- **Wave 6 Phase 2 + 3** — intent launchers + PNG/QR (deferred from Phase 1)

- **Wave 7 Silent-failure observability** — full design doc at `docs/design-reviews/silent-failures-2026-04-20.md`. 3-item MVP: `error_logs` + `_loudSwallow` + lint rule; boot self-check / Diagnostics screen; `publish_health` view + daily WhatsApp ping.

- **Wave 8 Sticky per-client defaults** — JSONB `client_exercise_defaults` on clients, 7 fields propagate forward-only, invisible UX. Also bundles landscape capture + "long-press to record video" hint.

- **Wave 9 Audit expansion** — full event log across plan_issuances + credit_ledger + referral_rebate_ledger + clients + practice_members + practice_invite_codes + new `audit_events` table for mutations without natural sources. Single `list_practice_audit` RPC. Filters + CSV export + page nav. Kind-chip palette coral/sage/red/grey. Depends on Wave 5 landing.

### Other deferred items

- Portal R-11 Change #3 — add-client affordance on `/clients`. Needs `upsertClient` on PortalApi + button + handler + route.
- Mobile R-11 twin for the portal's practice-rename inline popover switcher.
- Replace `sign_storage_url` pgjwt with Edge Function calling Supabase's native `createSignedUrl` — tech debt, important before Supabase retires the legacy JWT secret path.

## Infrastructure state

- **iPhone CHM** has **PR #68** installed (3-state publish + insert-dot haptic both passing).
- **Supabase vault** — `supabase_jwt_secret` populated with real legacy HS256 secret (Carl ran `vault.update_secret` in terminal). Signed URLs resolve. DO NOT rotate this secret — no PR captures what to do if it's rotated.
- **Raw-archive bucket** — 2 of 3 files for plan `fafad10e-3097-415e-982b-2226d3b8c14c` uploaded (exercises 1 + 3). Exercise 2 (`63f36b4d-...`) missing; would need a re-publish to catch up. Non-blocking.
- **Docs server** — `_server.py` on port 3457; may or may not still be running. Restart command in prior checkpoint.
- **install-device.sh** — now builds `--profile` mode (not release). Build-time `flutter clean` should still be manual if DerivedData corrupts (happened once; `rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*`).

## Known issues in this environment

- **Background sub-agents die silently in long sessions.** 4+ died today across the marathon. No clear root cause but it's correlated with: long main-session context, parallel spawns (4–6 at once), VPN drops. **Fresh session should help.** If sub-agents die again, fall back to sequential single-agent spawning or do the work inline.
- **Settings watcher caveat** — `.claude/settings.json` hook only activates in sessions that had it present at session start. If Carl starts a new session, hook activates automatically.

## Locked decisions (do not re-derive)

**From earlier checkpoint (still in force):**
- Line-drawing v6 constants (`lineAlpha=0.96`, `backgroundDim=0.70`, etc.)
- Credit model 3/8/5%-goodwill
- Audio concurrent-drain fix
- Logo v2 geometry
- Practitioner-facing thumbnails = B&W; client-facing = line

**New today:**
- **Mobile preview plays local files only.** No remote URLs on the Dart side. See `memory/feedback_mobile_preview_local_only.md`.
- **Web player has no client-facing treatment picker.** `exercise.preferred_treatment` is the authority.
- **Creating a new entity never opens a popup.** Default name + navigate + inline rename. See `memory/feedback_no_popups_ever.md`.
- **Sub-agent briefs use repo-relative paths.** Absolute paths seduce agents into writing to main. See `memory/feedback_agent_worktree_isolation.md`.

## How to resume

1. Read `CLAUDE.md`.
2. Read `docs/CHECKPOINT_2026-04-20.md` (original, earlier today).
3. Read THIS DOC.
4. Read memory files — all `feedback_*.md` entries, the silent-failures design review, the BACKLOG.
5. Check PR list with `gh pr list --state open` — should be empty or near-empty.
6. Ask Carl what he wants to pick up. Default priority:
   1. Re-spawn **Wave 4 Phase 1** (unified player prototype) — hook should protect it this time.
   2. Re-spawn **Q2 card-UI batch** (rep duration pills + set rest) — same.
   3. Continue **Wave 5 Members** — spec is locked, ready to implement.

**Carl's likely first prompt:** "where were we?" → point at this doc + summarise in 3 bullets + ask what he wants to pick up. Prefer the dead-agent re-spawns first since they're the most queued state.
