# Safe Mode v2 — face embedding round-trip device QA (2026-05-23)

**Branch:** `staging` tip after PR #455 merged.
**Build:** profile mode, SHA `036942f`, installed on iPhone CHM via `homefit-install-device` skill.
**Bundle:** `studio.homefit.app.dev`.

PR #455 fixes the embedding-bytea-encoding bug: the Dart `Uint8List` was being JSON-serialised as `[255,128,...]` which PostgreSQL was casting to a 7253-byte bytea. The fix encodes the embedding as a `\x`-prefixed hex string (PostgREST's canonical bytea input format) before passing to `setClientFaceEmbedding`.

This script verifies the end-to-end round-trip: enrol on device → 2048 bytes land on the server → consent withdrawal zeroes the row.

## Table of contents

- [Prerequisites](#prerequisites)
- [A. Enrol embedding from device](#a-enrol-embedding-from-device)
- [B. Withdraw consent zeroes the embedding](#b-withdraw-consent-zeroes-the-embedding)
- [C. Capture screen unblocks once embedding ready](#c-capture-screen-unblocks-once-embedding-ready)
- [D. Capture-time face matching (v2 photo pipeline)](#d-capture-time-face-matching-v2-photo-pipeline)
- [E. Debug-gated v2 threshold tuning sheet](#e-debug-gated-v2-threshold-tuning-sheet)
- [F. Portal audit feed includes capture events](#f-portal-audit-feed-includes-capture-events)

## Prerequisites

A staging client row with `safe_mode_face_recognition = true` consent. If you don't have one ready, open Clients → pick any client → Settings → toggle Safe Mode face recognition ON.

## A. Enrol embedding from device

- [ ] 1. Open the app on the iPhone. Navigate to the chosen client. Tap into a session → Camera mode.
- [ ] 2. Top of the viewfinder shows the Safe Mode v2 banner with a **Prepare a face fingerprint** CTA. Tap it.
- [ ] 3. Brief "Preparing…" spinner appears. Capture buttons should re-enable within ~2 seconds.
- [ ] 4. Run this SQL against staging (project `vadjvkmldtoeyspyoqbx`) — replace `<client_id>` with the row's UUID:
  ```sql
  SELECT name, length(face_embedding) AS bytes, face_embedding_model_version
  FROM clients WHERE id = '<client_id>';
  ```
  Expected: `bytes = 2048`, `face_embedding_model_version = 1`.

## B. Withdraw consent zeroes the embedding

- [ ] 5. Back out to the client detail screen. Toggle the **Safe Mode face recognition** consent OFF.
- [ ] 6. Re-run the SQL from item 4. Expected: `face_embedding IS NULL` (the length column should show NULL too).
- [ ] 7. Toggle consent back ON. The CTA on the Safe Mode banner reappears (no embedding stored yet).

## C. Capture screen unblocks once embedding ready

- [ ] 8. With consent ON and no embedding present, capture buttons should be greyed out / non-functional in the viewfinder.
- [ ] 9. Tap **Prepare a face fingerprint**. After the brief spinner, capture buttons re-enable.
- [ ] 10. Take one photo + one video to confirm the unblock holds through normal capture.

## D. Capture-time face matching (v2 photo pipeline)

Verifies the conversion service now routes capture-time photo Safe Mode through `applySafeModeV2ToPhoto` (face-recognition match) instead of the removed v1 anchor-box method. Prerequisite for the section: items 1-4 passed, embedding is present on the server AND cached locally on the device (the latter is guaranteed by re-launching the app after the enrol step). The enrolled client must be the active session client and the device must be inside an enforcing premises polygon.

- [ ] 11. With the enrolled client active and inside an enforcing premises, take a photo of yourself standing beside another person (a bystander). Open the Studio card thumbnail — your face should remain sharp, the bystander's face and silhouette should be coral-overlay'd in the safe variant.
- [ ] 12. Same setup. Step **behind** the bystander so they are noticeably closer to the camera (their bounding box is now the larger one). Take a photo. Under v1 anchor-box this would have flipped — the bystander would have been treated as the subject and YOU would have been coral'd. Under v2 the embedding should still identify YOU as the subject, your face stays sharp, the bystander gets coral. This is the key regression v2 fixes.
- [ ] 13. Step out of the frame entirely and take a photo of just the bystander. Vision detects their face but no face matches your stored embedding above threshold, so the v2 pipeline falls into "no subject mode" (per the Swift spec at `VideoConverterChannel.swift:3011-3013`): every detected face gets coral-painted in its head-expanded bbox; silhouettes stay sharp. The bystander's face should be coral'd; their body silhouette stays visible. The capture is NOT rejected (per `VideoConverterChannel.swift:2800-2806`, `missRate = 0.0` in the no-subject case is intentional — the solo-back-view safety guarantee).
- [ ] 14. SQL spot-check on staging — replace `<exercise_id>` with the id of the photo captured in item 11 or 12:
  ```sql
  SELECT id, media_type, safe_mode_active, safe_mode_algorithm_version
  FROM exercises WHERE id = '<exercise_id>';
  ```
  Expected: `media_type = 'photo'`, `safe_mode_active = true`, `safe_mode_algorithm_version = 2`. Use `mcp__supabase__execute_sql` against staging project `vadjvkmldtoeyspyoqbx`.
- [ ] 15. Race-condition test: with consent ON + embedding cached, open Camera mode, take a photo, IMMEDIATELY force-quit the app (swipe up + flick) before the conversion has finished. Relaunch. The cached embedding may have been evicted on cold start before the queued conversion resumes. Expected: the exercise row is gone (rejected); a coral-bordered toast surfaces at the top of the viewfinder reading something like `Face fingerprint isn't ready — try again in a moment`. The half-converted exercise must NOT survive into the Studio list with `safeRawFilePath = null` (which would publish un-blurred bystanders).
- [ ] 16. Re-take the same selfie burst from item 11. With threshold lowered to 0.5 + head-expansion clamped to 35% area, ALL captures should now render with face sharp (subject identified) rather than the whole frame blurred. Pull device logs via `xcrun devicectl device process view --device 00008150-001A31D40E88401C --console | grep "SafeMode v2"` during a capture to see per-face cosine similarities. Expected: cosSim values for self in the 0.45-0.70 range (above the new 0.5 threshold consistently).
- [ ] 17. Cold-start rehydration: with embedding already enrolled for the active client, force-quit the app (swipe up + flick away). Relaunch and open the same client → new session. Safe Mode banner should immediately show ready (capture buttons enabled, no "Prepare a face fingerprint" CTA). Tap capture — the native call should fire with the rehydrated embedding without any re-generation. Confirmed via the `[SafeMode v2] face[0] cosSim=...` line appearing in the device log on the very first capture after relaunch.

## E. Debug-gated v2 threshold tuning sheet

Verifies the long-press tuning sheet that lets us iterate on the v2 face-match threshold without rebuilds. Gated by `debugTuningGateActive()` (`kDebugMode || AppConfig.env == 'staging'`) — release/prod builds get a no-op wrap and never see the affordance. Persists chosen values to SharedPreferences under `safe_mode_v2_threshold_override` so future captures pick them up automatically.

- [ ] 18. With staging build installed: open Studio, long-press a Safe-Mode photo card. Tuning sheet slides up with a slider centered on 0.500 (or the last saved override). Photo thumbnail visible at top.
- [ ] 19. Drag the slider down to ~0.30, release. Spinner appears briefly on the photo preview; preview updates to the new re-composited safe variant. The face that was previously coral'd as a bystander should now show as the subject (sharp) because the looser threshold accepted the match.
- [ ] 20. Tap "Save default", close the sheet, take a fresh selfie. The new capture uses the saved 0.30 threshold automatically (verify by long-pressing the new exercise → slider initial value reads 0.30). Tap "Reset" to clear → next capture uses const 0.50 again.
- [ ] 21. Long-press the Hero thumbnail on a Safe-Mode photo Studio card → tuning sheet slides up. (Previously the long-press was swallowed by drag-to-reorder.) Verify that long-pressing the TEXT column of the same card still triggers drag-to-reorder (long-press elsewhere on the card → card lifts for drag).
- [ ] 22. Long-press the bottom-rail Hero thumb in the editor sheet (small 56x40 thumbnail in the header) → tuning sheet slides up.
- [ ] 23. Open the tuning sheet from any surface. The preview thumbnail at the top of the sheet is now prominently sized (about half the sheet height) with a "Safe variant — re-composites live as you drag" label. Drag the slider; the preview updates with a brief coral border flash on each successful re-composite.

## F. Portal audit feed includes capture events

Verifies the unified `/audit` page now shows every photo and video captured alongside plan publishes, credits, members, etc. Backed by the extended `list_practice_audit` RPC + the `capture_audit_events` table populated by PR #462.

- [ ] 24. Take a photo while inside an enforcing premises (Safe Mode active). Open the portal `/audit` page on the same practice (`https://manage.homefit.studio/audit?practice=<staging_practice_id>`). A new row appears at the top with the kind chip **Photo captured** (coral), actor = you (your practitioner email), client = the active session's client (linked), and the description column shows `Photo captured · build <sha>` with a coral **Safe Mode** badge and a grey premises-name badge underneath. SQL spot-check via `mcp__supabase__execute_sql` against staging project `vadjvkmldtoeyspyoqbx`:
  ```sql
  SELECT id, kind, started_at, metadata
  FROM capture_audit_events
  WHERE trainer_id = '<your_user_id>'
  ORDER BY started_at DESC LIMIT 3;
  ```
  Expected: most recent row has `kind = 'photo'`, `metadata->>'safe_mode_active' = 'true'`, `metadata->>'exercise_id'` matching the photo just captured.
- [ ] 25. Sign in to the portal as a different practice owner (or switch active practice via the practice picker chip) and reload `/audit`. The capture event from item 24 must NOT appear in this practice's feed — RLS scoping via `user_practice_ids()` holds. Repeat with `?practice=<other_practice_id>` in the URL to belt-and-braces the practice-scoping.
- [ ] 26. Local persistence after enrol: with consent ON + no embedding, tap "Prepare a face fingerprint". After the spinner clears, immediately force-quit the app (swipe up + flick). Relaunch and open the same client → new session. Safe Mode banner should show ready IMMEDIATELY (no "Prepare a face fingerprint" CTA), no waiting for SyncService to catch up. SQL spot-check: `SELECT length(face_embedding) FROM clients WHERE id = '<client_id>';` returns 2048 (already verified by item 4); the meaningful new behaviour is that the LOCAL SQLite row also has the bytes the moment enrolment finishes.
