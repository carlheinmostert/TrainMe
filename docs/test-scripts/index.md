# Device QA test scripts

Open each script in Claude Code Desktop's preview pane via `Cmd+Shift+V`. Give pass / fail feedback in the chat terminal — state lives in the conversation, the .md is the spec.

## Active wave

- [2026-05-25 — Safe Mode v2 enrolment polish Phase 2](2026-05-25-safe-mode-v2-enrolment-polish-phase2.md) — stacked PR on Phase 1 #491. Real-time pose-gated capture + per-embedding quality scoring + manual avatar selection grid. 20 items across A-E.
- [2026-05-25 — Safe Mode v2 enrolment polish Phase 1](2026-05-25-safe-mode-v2-enrolment-polish-phase1.md) — PR #491. Camera flip toggle + consent matrix scaffolding + consent sheet restructure + avatarOnly simple-shot mode.
- [2026-05-25 — Safe Mode v2 photo colorspace + reprocess affordance](2026-05-25-safe-mode-photo-colorspace.md) — staging tip `277e839`. PRs #482 (DeviceRGB output colorspace, kills dark + whole-frame-blur) + #485 (algo version bump to 3, surfaces re-process row on existing dark captures).
- [2026-05-24 — Safe Mode v2 multi-reference enrolment](2026-05-24-safe-mode-multi-ref-enrolment.md) — staging tip pre-`277e839`. Wave-A through Wave-E enrolment flow + chip + capture intercept. Items 1-15 remain valid on the new build (a strict improvement; re-walk if time).

## Past waves

- [2026-05-23 — Safe Mode v2 face embedding round-trip](2026-05-23-safe-mode-embedding-roundtrip.md) — closed after PR #455 verified end-to-end.
- [2026-05-23 — Per-premises live URLs](2026-05-23-per-premises-urls.md)
- [2026-05-23 — Live view cosmetic pass](2026-05-23-live-view-cosmetic-pass.md)
- [2026-05-21 — Safe Mode Phase 1 + 2](2026-05-21-safe-mode.md)
- Earlier waves under `docs/test-scripts/` (historical HTML format; superseded by Markdown after 2026-05-21).

See `feedback_test_scripts_as_markdown.md` in memory for the format rule.
