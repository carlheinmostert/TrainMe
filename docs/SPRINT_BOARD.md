# Sprint Board - Stabilization Wave
Last updated: 2026-05-01 (post-T1 merge + first seam burn-down)
Owner: Carl + Cursor agent
Cadence: update on every PR open/merge and daily wrap

## Rules (Keep us honest)
- Only one card in `In Progress` at a time.
- A card moves to `Done` only when all Done Criteria are met.
- Every card must include PR link(s) and verification evidence.
- If blocked > 1 day, move to `Blocked` with explicit unblock action.

---

## Ready

### T3 - Web Player Drift Guard
- Priority: P0
- Effort: S
- Owner: Web/Platform
- Goal: Prevent divergence between `web-player/*` and `app/assets/web-player/*`.
- Local check: `python3 tools/check_web_player_drift.py`
- Done Criteria:
  - [ ] Sync/hash verification check in CI
  - [ ] Fails on drift
  - [ ] PR(s) linked
  - [ ] One proof run attached

---

## In Progress

### T2 - Publish Reliability Classification
- Priority: P0
- Effort: M
- Owner: Mobile + Backend
- Goal: Remove silent ambiguity in publish side effects.
- Done Criteria:
  - [ ] Classification table documented
  - [ ] Handling behavior implemented for each class
  - [ ] User-visible/diagnostic status exposed
  - [ ] PR(s) linked
  - [ ] Verification script/results attached

---

## Done (merge lane)
- `#157` merged (docs handoff/checkpoint).
- `#158` merged (Wave 41 ghost-exercise port).
- `#156`, `#155`, `#154`, `#153` merged tip-first (DOSE stack).
- `#146` merged (body-focus mobile + schema).
- `#147` merged (web-player overrides).
- Superseded PRs closed: `#145`, `#149`, `#150`, `#151`, `#152`.
- Linked Supabase DB: Wave 42 migration applied safely.
- `#163` merged — **T1 Enforce Data Access Seams** (CI seam rule + exceptions policy).
- T1 burn-down follow-up: web-player close-event analytics now routes via `HomefitApi.logAnalyticsEvent` (removed direct `/rest/v1/rpc` from `app.js`).

---

## Open PR Triage (current)
- `#110` draft — CI strategy work vehicle (candidate for T1/T5).
- `#108` open — design-system v1.2 (revalidate against current tokens).
- `#35` open — docs-only business case (safe merge candidate).
- `#10` open — stale base (`bisect/studio-circuit-header`), retarget/close.
- `#9` open — stale + conflicting (`bisect/studio-circuit-header`), close/recreate.
- `#1` draft — stale CVE branch, refresh against current dependencies.

### Recommended next order
1. Continue T1 exception burn-down (Flutter direct `Supabase.instance.client` usages).
2. Progress `T2` publish reliability classification.
3. Revisit stale PR triage lane (`#110`, `#108`, `#10`, `#9`, `#1`) as needed.

