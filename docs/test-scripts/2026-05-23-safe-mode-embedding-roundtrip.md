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
