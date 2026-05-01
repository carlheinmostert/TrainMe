# Sprint Board - Stabilization Wave
Last updated: 2026-05-01
Owner: Carl + Cursor agent
Cadence: update on every PR open/merge and daily wrap

## Rules (Keep us honest)
- Only one card in `In Progress` at a time.
- A card moves to `Done` only when all Done Criteria are met.
- Every card must include PR link(s) and verification evidence.
- If blocked > 1 day, move to `Blocked` with explicit unblock action.

---

## Ready

### Recommended next order
1. **T2 publish reliability** — classification doc landed (`docs/T2_PUBLISH_RELIABILITY.md`); remaining Done Criteria need explicit UX/engineering passes where noted there.
2. **T1 Flutter seam burn-down** — shrink [`exceptions/direct_supabase_usage_exceptions.yaml`](../exceptions/direct_supabase_usage_exceptions.yaml) allowlist per Cursor seam rule (#165); `#163` / `#164` merged baseline.
3. **Stale PR re-triage** — revisit numbered PRs below on GitHub (don't infer merged state from this board alone).

---

## In Progress

### T2 - Publish Reliability Classification
- Priority: P0
- Effort: M
- Owner: Mobile + Backend
- Goal: Remove silent ambiguity in publish side effects.
- Doc: [`docs/T2_PUBLISH_RELIABILITY.md`](T2_PUBLISH_RELIABILITY.md)
- Done Criteria:
  - [x] Classification table documented
  - [ ] Handling behavior implemented for each class
  - [ ] User-visible/diagnostic status exposed
  - [ ] PR(s) linked
  - [x] Verification checklist documented *(manual steps — [`Verification`](T2_PUBLISH_RELIABILITY.md#verification); no standalone script)*

Gaps for unchecked criteria are spelled out under **Known ambiguity / gaps** in the linked doc.

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
- `#164` merged — companion seam-policy tooling/doc baseline for T1.
- Cursor seam rule `#165` — Flutter-side deny-by-default direct Supabase usage (allowlisted YAML exceptions).
- T1 burn-down follow-up: web-player close-event analytics now routes via `HomefitApi.logAnalyticsEvent` (removed direct `/rest/v1/rpc` from `app.js`).
- **T3 Web Player Drift Guard:** `.github/workflows/web-player-drift-guard.yml` runs `python3 tools/check_web_player_drift.py` on PR + push to `main`; fails CI on hash drift between `web-player/*` and `app/assets/web-player/*`.

---

## Open PR Triage (re-triage on GitHub)
Historical/low-confidence rows dropped — verify titles and merge readiness in the GitHub PR list before acting.

---
