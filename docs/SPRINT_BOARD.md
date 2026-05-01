# Sprint Board - Stabilization Wave
Last updated: 2026-05-01 (T2 closeout + hardening wave through #175)
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
1. **Publish reliability hardening follow-up** — continue non-blocking edge-case hardening listed in [`docs/BACKLOG.md`](BACKLOG.md) under “T2 follow-up” (next: refund-failure surfacing in visible UI/support path).
2. **Device QA pass for T2 diagnostics** — verify publish-failure copy/clipboard on iPhone for offline/JWT/permission paths.
3. **Refresh sprint board cadence** — keep this board synced as new hardening PRs land.

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
- `#164` merged — web-player `plan_closed` analytics routes through `HomefitApi.logAnalyticsEvent` (no direct `/rest/v1/rpc` in `app.js`).
- `#165` merged — Cursor rule always ends finished-task replies with **What's next** (`.cursor/rules/trainme-whats-next.mdc`).
- [`#166`](https://github.com/carlheinmostert/TrainMe/pull/166) merged — T2 classification doc + sprint board refresh.
- [`#167`](https://github.com/carlheinmostert/TrainMe/pull/167) merged — curated `PublishFailurePayload` for publish `networkFailed` + Studio copy-to-clipboard diagnostics.
- [`#171`](https://github.com/carlheinmostert/TrainMe/pull/171) merged — T2 hardening follow-up: explicit refund-outcome uncertainty + remote-version-drift diagnostics in publish failure payloads.
- [`#172`](https://github.com/carlheinmostert/TrainMe/pull/172) merged — T1 web-player seam tail closed (allowlist retired) + docs-canvas examples:
  - [`docs/canvas_publish_pipeline_architecture.md`](canvas_publish_pipeline_architecture.md)
  - [`docs/canvas_data_access_seams_t1_t2.md`](canvas_data_access_seams_t1_t2.md)
- [`#173`](https://github.com/carlheinmostert/TrainMe/pull/173) merged — sprint board synchronized after `#171/#172`.
- [`#174`](https://github.com/carlheinmostert/TrainMe/pull/174) merged — T2 hardening: consent preflight skip observability surfaced while preserving server backstop.
- [`#175`](https://github.com/carlheinmostert/TrainMe/pull/175) merged — sprint board closeout refresh after `#174`.
- **T2 closed** — Publish Reliability Classification done for sprint scope:
  - [x] Classification table documented ([`docs/T2_PUBLISH_RELIABILITY.md`](T2_PUBLISH_RELIABILITY.md))
  - [x] Handling behavior implemented for documented classes (including structured `networkFailed` copy/diagnostics)
  - [x] User-visible/diagnostic status exposed
  - [x] PR(s) linked (`#166`, `#167`, this closeout PR)
  - [x] Verification checklist documented
- Residual non-blocking reliability edge-cases moved to [`docs/BACKLOG.md`](BACKLOG.md) (**T2 follow-up**).
- **T3 Web Player Drift Guard:** `.github/workflows/web-player-drift-guard.yml` runs `python3 tools/check_web_player_drift.py` on PR + push to `main`; fails CI on hash drift between `web-player/*` and `app/assets/web-player/*`.

---

## Open PR Triage (re-triage on GitHub)
Current status (2026-05-01): **no open PRs**.
Historical/low-confidence rows remain dropped — re-check GitHub PR list before adding new merge-lane items.

---
