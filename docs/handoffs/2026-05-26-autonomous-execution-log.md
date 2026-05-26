# Autonomous execution log — artifact-system implementation

**Date:** 2026-05-26 (started while Carl was AFK)
**Operator:** Claude (this session)
**Scope:** Implementation Waves 1–5 of the artifact-system design ratified in `docs/ARTIFACT_SYSTEM.md`
**Authority:** Carl said "execute subsequent waves as well and document your decisions so that I can review them when I get back."

This document is the running record of every consequential decision I made without Carl in the room, plus the state of each wave at handoff. Read this before the individual wave PRs.

## Decision standing-rules (apply to all waves)

1. **Branch from `origin/staging`**, NOT main. Per `feedback_branch_sub_agent_from_staging.md`. Each wave gets its own branch named `feat/artifact-{slug}` off staging.
2. **PR target = `staging`**, never main. Carl explicitly promotes staging → main; I don't touch that boundary.
3. **No iOS device install, no TestFlight, no `flutter run`.** Per `feedback_ask_before_mobile_deployment.md`. Simulator builds OK for verification.
4. **Schema migrations as files only.** No `supabase db push`, no `mcp__supabase__apply_migration`, no dashboard SQL editor. Per `feedback_supabase_branching_one_source.md`. If Branching is wedged on staging (per 2026-05-11 incident), I'll attempt `supabase db query --linked --file` from this session as the documented "last resort" path and flag the manual-apply state in the wave's PR body. If that path also fails I PAUSE and report.
5. **All reads/writes through enumerated RPCs.** Per `feedback_no_direct_db_access.md`. Never `from('table').select()` from `api.js` / `api_client.dart` / `api.ts`. The per-surface access layer files are the only enumerated surface.
6. **Vocabulary:** "workout handout" + "workout player" (never "overview" / "interactive player"). "Practitioner", never trainer/coach/bio/physio in copy. Single coral accent.
7. **Reader-App safe:** no purchase paths, no buy buttons, no price strings in the Flutter app. "Save your plan" / "Spend N credits" are OK. Top-up always at `manage.homefit.studio`.
8. **R-10 parity** only where it applies (player UX changes touch both `app/` and `web-player/`). The handout is web-only — no Flutter mirror needed.
9. **homefit.studio wordmark** — `.studio` (dot + word) is coral, not muted grey. Per `feedback_homefit_studio_wordmark.md`. The seal uses `--seal-coral` / `--seal-coral-light` at `:root`, never overridden by `.skin-{name}` classes.
10. **Sub-agents:** repo-relative paths, no `/Users/chm/dev/TrainMe/...` absolute prefixes. Per `feedback_agent_worktree_isolation.md`.
11. **Watchers print, they don't merge.** Per `feedback_sub_agent_watcher_prints_only.md`. I do the merging.

## Wave 1 — Foundation (handout + multi-kind publish)

**Branch:** `feat/artifact-handout-foundation`
**Status:** Dispatched 2026-05-26 — agent running (id `aa36619ac717a1a72`)
**Brief:** see the parent session's last Agent dispatch
**Reading order for review:** `docs/ARTIFACT_SYSTEM.md` (the design) → ADRs 0022, 0025, 0027 → this wave's PR

### Decisions made without Carl

(populated when the agent returns)

### Pre-flight findings against live staging DB

(populated when the agent returns)

### Manual-apply state

(populated when the agent returns — whether Branching CI worked or `supabase db query --linked --file` was required)

---

## Wave 2 — Claim + consumer identity

**Branch:** `feat/artifact-claim-consumer-identity` (planned)
**Status:** Queued

### Locked decisions Carl approved before stepping away

- **Auth model:** reuse `auth.users` for claimed consumers (same row type as practitioners, differentiated by which side of the relationship they sit on).
- **Link-table:** new `client_accounts (consumer_user_id, practice_client_id, consent jsonb, claimed_at, created_at)` PRIMARY KEY `(consumer_user_id, practice_client_id)`. One row per consumer × practice relationship; consent jsonb overrides `clients.video_consent` once it exists.
- **Plan-claim mechanism:** extend the existing `plan_invitations` table (shipped on staging with the self-trainer wave) with a `claimed_by_user_id` column + status transition.
- **Routes:** `/me` (consumer's My Workouts) and `/me/data` (consent panel) — locked during visual phase walkthrough.

### Decisions made without Carl

(populated when the wave runs)

---

## Wave 3 — Practitioner publish surfaces

**Branch:** `feat/artifact-publish-gate` (planned)
**Status:** Queued

### Scope

- Multi-select publish gate UI in Flutter (mockup at `docs/design/mockups/2026-05-26-publish-gate.html`)
- Studio AppBar artifact-status row (mockup section 1 in `2026-05-26-studio-status-bits.html`)
- Edit-lock chip → paid-only logic per ADR 0028 (free-only plans never lock; the chip arms only after a paid artifact is published)
- Share sheet two-path split: mockup at `2026-05-26-share-sheet.html`. (Could also live in Wave 5; see decision.)

### Decisions made without Carl

(populated when the wave runs)

---

## Wave 4 — Brand-skin subscription

**Branch:** `feat/artifact-brand-skin-subscription` (planned)
**Status:** Queued

### Locked decisions Carl approved before stepping away

- **Price:** 4 credits/month (R100 at R25/cr).
- **Trial:** 30-day free trial on first subscription (debit starts day 31).
- **Lapse grace:** 7-day window with banner before chrome reverts.
- **Scope:** one skin per practice (multi-practice practitioner subscribes each independently).
- **Ledger kind:** `brand_skin_month`, `metadata = '{"practice_id": "<uuid>"}'`.
- **Renewal:** manual re-up via portal subscribe surface, push-notification reminder at day 25 (mirrors ADR 0021 Safe Mode pattern).
- **CSS architecture:** `.skin-{name}` class overrides `--brand-default` + `--brand-light` + `--brand-tint-bg` + `--brand-tint-border` + `--brand-glyph-bg`; `--seal-coral` + `--seal-coral-light` at `:root` never overridden.

### Decisions made without Carl

(populated when the wave runs)

---

## Wave 5 — Share sheet + managed email

**Branch:** `feat/artifact-share-managed-email` (planned)
**Status:** Queued

### Scope

- Share sheet two-path UI in Flutter (mockup at `2026-05-26-share-sheet.html`) — if not already in Wave 3.
- Edge function for Resend-backed "managed email" send with the branded artifact link.
- `clients.email` write path (the practitioner-typed transient email, deleted when a verified claim email supersedes per ADR 0024).

### Decisions made without Carl

(populated when the wave runs)

---

## Outstanding for Carl to review on return

(populated as I go — anything that needed a defensible call I'll log here so you can override before final merge)

## Final state at handoff

(populated at the end — links to all PRs, current staging tip, any unresolved blockers)
