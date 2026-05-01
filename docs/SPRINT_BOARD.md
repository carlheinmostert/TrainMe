# Sprint Board - Stabilization Wave
Last updated: 2026-05-01 (post-merge update)
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

## Review

### T1 - Enforce Data Access Seams
- Priority: P0
- Effort: M
- Owner: Platform
- Goal: Prevent direct Supabase usage outside approved API seam files.
- Done Criteria:
  - [ ] CI rule added
  - [ ] Existing violations enumerated
  - [ ] New violations fail CI
  - [ ] Exception policy documented
  - [ ] PR(s) linked

---

## Done (merge lane)
- `#157` merged (docs handoff/checkpoint).
- `#158` merged (Wave 41 ghost-exercise port).
- `#156`, `#155`, `#154`, `#153` merged tip-first (DOSE stack).
- `#146` merged (body-focus mobile + schema).
- `#147` merged (web-player overrides).
- Superseded PRs closed: `#145`, `#149`, `#150`, `#151`, `#152`.
- Linked Supabase DB: Wave 42 migration applied safely.

---

## Open PR Triage (current)
- `#110` draft — CI strategy work vehicle (candidate for T1/T5).
- `#108` open — design-system v1.2 (revalidate against current tokens).
- `#35` open — docs-only business case (safe merge candidate).
- `#10` open — stale base (`bisect/studio-circuit-header`), retarget/close.
- `#9` open — stale + conflicting (`bisect/studio-circuit-header`), close/recreate.
- `#1` draft — stale CVE branch, refresh against current dependencies.

### Recommended next order
1. Confirm Wave 42 smoke test later (deferred).
2. Implement `T3` drift guard CI check.
3. Triage stale PRs (`#35`, `#10`, `#9`, `#1`, `#108`, `#110`).
4. Start `T1` CI seam enforcement.

