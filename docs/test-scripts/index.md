# Device QA test scripts

Open each script in Claude Code Desktop's preview pane via `Cmd+Shift+V`. Give pass / fail feedback in the chat terminal — state lives in the conversation, the .md is the spec.

## Active wave

- [2026-05-25 — Three-wave install (self-trainer + Safe Mode v2 video + Exercise Clipboard)](2026-05-25-three-wave-install.md) — staging tip `674e2ef`. 18 ios-impact PRs across three parallel sessions. 29-item cross-cutting check with links to 17 per-PR scripts for drill-down.

## Past waves

- [2026-05-25 — Safe Mode v2 photo colorspace + reprocess affordance](2026-05-25-safe-mode-photo-colorspace.md) — superseded by the three-wave install above; #482 + #485 are bundled in.
- [2026-05-24 — Safe Mode v2 multi-reference enrolment](2026-05-24-safe-mode-multi-ref-enrolment.md) — superseded by the three-wave install (#491 + #496 enrolment polish bundled in).

- [2026-05-23 — Safe Mode v2 face embedding round-trip](2026-05-23-safe-mode-embedding-roundtrip.md) — closed after PR #455 verified end-to-end.
- [2026-05-23 — Per-premises live URLs](2026-05-23-per-premises-urls.md)
- [2026-05-23 — Live view cosmetic pass](2026-05-23-live-view-cosmetic-pass.md)
- [2026-05-21 — Safe Mode Phase 1 + 2](2026-05-21-safe-mode.md)
- Earlier waves under `docs/test-scripts/` (historical HTML format; superseded by Markdown after 2026-05-21).

See `feedback_test_scripts_as_markdown.md` in memory for the format rule.
