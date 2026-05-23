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
