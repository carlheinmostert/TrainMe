# 2026-05-21 Quality review — staging vs main

Scope: 4 migrations (safe_mode, safe_mode_fix_42702, public_profile_v2, practice_public_members, safe_mode_completion), Safe Mode pipeline (Swift + Dart), Public Profile v2 portal editor, web player `/v/{slug}`, and the embedded preview bridge. Focus is testability + error handling + edge cases.

## Table of Contents

- [Critical](#critical)
- [High](#high)
- [Medium](#medium)
- [Low / observation](#low--observation)

## Critical

1. **Photo Safe Mode silently bypasses to un-blurred raw on cloud upload.** `app/lib/services/upload_service.dart:2429` — `absRaw = useSafeVariant ? (exercise.absoluteSafeRawFilePath ?? exercise.absoluteRawFilePath) : exercise.absoluteRawFilePath`. When `safeRawFilePath` is set but the `_safe.jpg` is missing on disk (iCloud-offloaded, manual prune, or the converter wrote the DB column but failed to flush bytes), this falls back to the un-blurred raw photo and uploads bystanders' faces to the cloud `raw-archive` bucket. The video sibling at `:2178` does the right thing (no fallback, skips upload). Fix: drop the `??` fallback — make photo behave like video and `continue` when the safe variant is set-but-missing. Defeats the entire fail-closed Safe Mode contract otherwise.

## High

2. **`get_practice_public_members` has no LIMIT / pagination** (`supabase/migrations/20260521151000_practice_public_members.sql:54`). Anon-readable RPC returns every row in `practice_members` for a listed practice. A practice with 200 members renders 200 cards on `/v/{slug}`. Fix: add `LIMIT 50` server-side + UI cap.

3. **`hydrateTeam` swallows API errors with no logging** (`web-player/v.js:158-194`). No try/catch; if `getPracticePublicMembers` rejects the unhandled promise just lands in the console as a generic rejection and the Team section stays hidden silently. Fix: wrap in try/catch + `console.error('hydrateTeam failed', e)`; show a "Team unavailable" placeholder when the RPC fails but the rest of the profile loaded.

4. **`/v/{slug}` outer catch shows "not found" for every error** (`web-player/v.js:379-382`). Empty `catch (_)` collapses 4xx, 5xx, network errors, and CSP failures all into the same "not-found" UI. A user with a transient network blip sees "this profile doesn't exist" instead of "couldn't load — retry". Fix: distinguish 404 (slug genuinely unknown) from other errors; log to console.

5. **LogoUploader race: two concurrent picks land at the same storage path.** `web-portal/src/app/public-profile/LogoUploader.tsx:53-71`. User picks file A → starts upload. Before A completes, picks file B (same extension). Both upload to `branding/{practiceId}/logo.png`; whichever finishes LAST wins on storage. If A finishes last, the `onUploaded(url)` call carries B's `Date.now()` cache-buster but A's bytes are live. Fix: ignore stale callbacks via an `AbortController` or a request-id token captured at pick time.

## Medium

6. **`feedback_no_exception_control_flow` violations — empty `catch (_) {}` with no logging.** `app/lib/services/upload_service.dart:2154` (raw-archive listing) and `:1241` (media-bucket listing). Both are fast-path existence checks; on failure the code correctly degrades to "upload everything", but the failure is invisible to observability. Fix: at minimum `debugPrint('listMedia failed, falling back to full upload: $e')` before the empty catch.

7. **`feedback_no_exception_control_flow` — analytics fire-and-forget with no console log.** `web-portal/src/lib/supabase/api.ts:2094-2099`. Explicit "analytics must never break share UX" comment is correct, but with zero logging we can't observe RPC outages. Fix: `console.warn('log_share_event swallowed:', err)`.

8. **`BrandColorPicker` doesn't validate values from DB before binding to `<input type="color">`.** `web-portal/src/app/public-profile/BrandColorPicker.tsx:25`. Reads `value` straight from props; if the DB ever holds an invalid string (the CHECK constraint should prevent this, but defence in depth) the color input renders unpredictably. Fix: regex-validate on render, fall back to coral.

9. **Single-frame photo Safe Mode = binary pass/fail.** `app/ios/Runner/VideoConverterChannel.swift:2651-2654`. A photo has `framesTotal=1`; if Vision misses once, `missRate=1.0` → rejected. A jittery hand or low light = no recovery path. Fix: for the photo path, fall back to a brief retry (process the same frame again with relaxed Vision confidence) before bubbling `SafeModeRejection`, OR document the UX (the test script item 87 wording already covers this).

10. **SafeModeRejection silently disappears from Studio UI.** `app/lib/services/conversion_service.dart:568-590` deletes the exercise row but does NOT emit on `_updateController` — only on `_rejectionController`. Studio mode subscribes to `onConversionUpdate`, not `onSafeModeRejection`. After a rejection, the deleted row may linger in Studio's in-memory list until the next pull/refresh. Fix: emit a synthetic deletion update on `_updateController` after the SQLite delete, OR have Studio also subscribe to `onSafeModeRejection` and trim its list there.

## Low / observation

11. **Test-script Section K items 84/86/91 require Supabase Studio + shell access** (`docs/test-scripts/2026-05-21-safe-mode.md:120-141`). Carl can verify these but a delegated tester can't. Flag in the script's preamble that K-{84,86,91} are "technical verifier only".

12. **`get_plan_full` widened return — no signature versioning.** Mobile + web player clients that pre-date the V2 widening will still get the new keys back; they ignore them by design but worth a coverage check on the older TestFlight build.

13. **Migration `20260521150000_public_profile_v2.sql` uses `DROP FUNCTION IF EXISTS` then `CREATE OR REPLACE`.** Correct for widening `RETURNS TABLE`, but if a per-PR Branching DB is mid-applied and the DROP races a `set_practice_public_profile` call from a parallel test session, the caller gets a transient 404. Worth a `BEGIN`/`COMMIT` wrap (already present at file boundaries — confirm the DDL is inside it).

14. **`cached_practices` brand/logo bridge runs synchronously in the preview path** (`app/lib/services/unified_preview_scheme_bridge.dart:124-143`). For a practice with many memberships this scans the full list with an O(n) loop. Trivial today; if Carl onboards a multi-practice user it'll be visible. Use a map lookup keyed by `practiceId`.

15. **SQLite v40 → v44 upgrade not exercised by `idempotent_migration_test.dart`.** The test exists (`app/test/idempotent_migration_test.dart`) but I didn't confirm it covers the skip-multiple-versions path (a user on v40 install bumps straight to v44, all four `oldVersion < N` blocks must each run independently). Worth a one-line assertion bump.

## Summary counts

- Critical: 1
- High: 4
- Medium: 5
- Low / observation: 5
