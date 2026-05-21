# 2026-05-21 — Code review (staging vs main)

Reviewer: senior code review pass over PRs #389-#402 (13 PRs, 211 commits, 257 files).
Specs reviewed: `docs/specs/2026-05-21-public-profile-v2-design.md`, `docs/specs/2026-05-21-safe-mode-completion-design.md`, `docs/plans/2026-05-21-*-plan.md`, `docs/SAFE_MODE_HANDOVER_2026-05-21.md`, `docs/CHECKPOINT_2026-05-21-coordination.md`.

## Verdict

Both waves match their specs. `replace_plan_exercises` carries every baseline column verbatim and appends only `safe_mode_active` + `captured_in_premises_id`. `get_plan_full` uses the spec-mandated `to_jsonb(plan_row) || jsonb_build_object(...)` pattern, preserving every existing branch (consent gates, treatment URL synthesis, thumbnail existence checks, sets aggregation, vault base URL). The `feedback_no_direct_db_access` `.from('practices').select(...)` at api.ts:797 is closed — replaced by `get_practice_profile_owner` RPC (`web-portal/src/lib/supabase/api.ts:820`). `_handlePageScroll` is single-definition in `app/lib/screens/session_shell_screen.dart` (no duplicate). Safe Mode rejection toast is inline, no modal (R-01 honoured). SQLite v44 lands with `safe_raw_file_path` migration. CLAUDE.md Safe Mode section is accurate.

## Critical

None.

## High

None.

## Medium

1. **api.ts `practice_members` direct selects pre-date V2 but were extended in this wave** — `app/lib/services/api_client.dart:316` and `web-portal/src/lib/supabase/api.ts:218,248,336` still use `.from('practice_members').select('... practices:practice_id ( id, name, brand_color, public_logo_url )')`. The Flutter side was expanded by this PR to embed two new branding columns. The violation pre-dates V2 but the diff makes it worse. Fix: introduce a `list_my_practices_with_branding` SECURITY DEFINER RPC and route both surfaces through it. Backlog item — does not block user testing.

2. **Orphaned `web-portal/src/components/PracticeProfilePanel.tsx`** — no longer imported anywhere; `PremisesListPanel.tsx:140` comment marks it as "retained for backport reference until the next cleanup wave". Delete in the cleanup wave to prevent confusion (it still imports `getPracticeProfileEditable` which no longer exists in the new shape).

## Low / observation

1. **`SafeModeRejection` is a typed exception used as a control-flow signal** — `app/lib/services/conversion_service.dart:243,569`. Borderline against `feedback_no_exception_control_flow`, but here the exception represents an actual rejection event (the capture genuinely failed); it is not catch-and-swallow-as-success. Comment at `:569-575` justifies the choice. Acceptable.

2. **Flutter R-10 parity for brand_color goes via the bundled WebView** — `app/assets/web-player/app.js` carries the cascade (same code as `web-player/app.js`); no separate Flutter `ThemeData` extension landed despite the spec calling for one. This is fine in practice because every Flutter preview surface that renders brand-tinted content is a WebView, so the CSS variable cascade is the single source of truth. Spec wording should be updated to reflect "bundle is the cascade carrier" rather than "ThemeData extension".

3. **Test script item 84 ("verify via Supabase Studio") is not self-checkable** — `docs/test-scripts/2026-05-21-safe-mode.md` section K. Requires Carl to log in and download the file from the storage browser. Item 86 has the same shape (cloud DB inspection). These pass-fail buttons can't auto-verify; flag for Carl to mark manually. Item 91's `PRAGMA user_version` is debug-only as the script itself acknowledges — testable only on simulator builds.

4. **`docs/SAFE_MODE_HANDOVER_2026-05-21.md` referenced from the review brief does not exist on staging** — only `docs/SAFE_MODE_HANDOVER.md` does. Brief references the dated copy; either rename for posterity or correct the pointer.

5. **`v.html` + `v.js` (Public Profile v2 surface) exist in `web-player/` and the synced bundle `app/assets/web-player/` but are not currently used by any Flutter WebView route** — anonymous visitors land here from `session.homefit.studio/v/{slug}`. Bundle inclusion is harmless but bloats the iOS app payload by ~9KB. Strip from the bundle in the next sync if/when `tool/sync_web_player_bundle.dart` gains an allowlist.

## Summary counts

- Critical: 0
- High: 0
- Medium: 2
- Low / observation: 5
